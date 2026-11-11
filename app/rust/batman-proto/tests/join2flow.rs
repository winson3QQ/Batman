//! join2flow (docs/design/254-app-join2.md v7.1 §3.3, tests T1-T4, T7, T8, T10): a second node joins the phone's
//! network against a fake node that checks every request on its own (owner-op signatures over the bodies it got, the
//! netcfg / members / secrets Sign1s with the admin key, net_secrets decrypted with ITS OWN ECDH key) and keeps a
//! radio country that settings/set changes. Every record write goes through the real Store::write_cas (a fake seal
//! that binds the AAD), so what a later step or a later session reads is what the earlier one wrote.

use batman_proto::cbor::{self, Value as V};
use batman_proto::conn::Conn;
use batman_proto::join2flow::{Action, End, Fail, Input, Join2, Keep, Pre, Revert};
use batman_proto::joinflow::NetRecord;
use batman_proto::mrec::MNet;
use batman_proto::netrec::{self, InviteRec, Member, MemberState, NetRec};
use batman_proto::nodecert::Verified;
use batman_proto::{cose, frame, kdf, noise, sig, store};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use p256::ecdsa::signature::{Signer, Verifier};
use serde_json::Value as J;
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

const FL: usize = 244;
const SAE: &str = "Sae0123456789abcdefghijk";
const NET_ID: [u8; 16] = [0x5a; 16];

fn vectors() -> J {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../tests/vectors/219-protocol/vectors.json");
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}
fn h(v: &J) -> Vec<u8> {
    hex::decode(v.as_str().unwrap()).unwrap()
}
fn m(pairs: Vec<(u64, V)>) -> V {
    V::Map(pairs.into_iter().map(|(k, v)| (V::Uint(k), v)).collect())
}
fn key(b: u8) -> p256::ecdsa::SigningKey {
    p256::ecdsa::SigningKey::from_slice(&[b; 32]).unwrap()
}
fn pub_of(k: &p256::ecdsa::SigningKey) -> [u8; 65] {
    k.verifying_key().to_sec1_point(false).as_bytes().try_into().unwrap()
}
fn nint(m: &V, n: u64) -> Option<&V> {
    let V::Map(e) = m else { return None };
    e.iter().find(|(k, _)| *k == V::Nint(n)).map(|(_, v)| v)
}
fn signed(k: u8, tbs: &[u8]) -> Vec<u8> {
    let s: p256::ecdsa::Signature = key(k).sign(tbs);
    s.to_der().as_bytes().to_vec()
}

// keys: 0x11 owner, 0x22 owner_enc, 0x66 admin; 0x55 / 0x43 the first node's DAC / ECDH; 0x77 / 0x42 the joining node's
const ADMIN: u8 = 0x66;
const OWNER: u8 = 0x11;
fn ecdh_pub(b: u8) -> [u8; 65] {
    pub_of(&key(b))
}
fn joining_node() -> Verified {
    Verified { device_id: "aabbccddeeff00112233".into(), dac_der: vec![], dac_pub: pub_of(&key(0x77)), ecdh_pub: ecdh_pub(0x42), sn: [0; 9] }
}
fn member(dac: u8, ecdh: u8, name: &str, state: MemberState) -> Member {
    Member {
        dac_pub_hash: netrec::dac_hash(&pub_of(&key(dac))),
        ecdh_pub: ecdh_pub(ecdh),
        name: name.into(),
        owner_pub: pub_of(&key(OWNER)),
        owner_enc_pub: pub_of(&key(0x22)),
        device_id: None,
        state,
        prev_country: None,
        known: None,
    }
}

/// A net record as make-network writes it (first node 0x55 / 0x43), netcfg v1 country `country`, admins `admins`.
fn record(country: &str, admins: &[[u8; 65]], state: &str, list: Option<Vec<Member>>) -> NetRec {
    let mesh = format!("bm-{}", hex::encode(&NET_ID[..6]));
    let p = cose::net_config_payload(&NET_ID, 1, None, "home", country, &mesh, 40, 4, admins);
    let netcfg = cose::sign1(cose::CT_NETCFG, &p, &sig::der_to_raw_low_s(&signed(ADMIN, &cose::sign1_tbs(cose::CT_NETCFG, cose::LABEL_NETCFG, &p))).unwrap());
    let first = member(0x55, 0x43, "node-0001", MemberState::Applied);
    let mp = cose::member_list_payload(
        &NET_ID,
        1,
        None,
        &[cose::Member { dac_pub_hash: &first.dac_pub_hash, ecdh_pub: &first.ecdh_pub, name: &first.name, owner_pub: &first.owner_pub, owner_enc_pub: &first.owner_enc_pub }],
    );
    let members = cose::sign1(cose::CT_MEMBERS, &mp, &sig::der_to_raw_low_s(&signed(ADMIN, &cose::sign1_tbs(cose::CT_MEMBERS, cose::LABEL_MEMBERS, &mp))).unwrap());
    let base = NetRecord { net_id: NET_ID, mesh_id: mesh, channel: 40, bw: 4, sae: SAE.into(), net_root: [0x77; 32], netcfg, members, secrets: vec![0xd2, 0x84] };
    NetRec { base, state: state.into(), list, invites: None, versions: None, departed: None }
}
fn applied_record(country: &str) -> NetRec {
    record(country, &[pub_of(&key(ADMIN))], "applied", None)
}

/// The real record store with a fake seal: sealed = SHA-256(aad) ‖ plain (opens only with the same path + generation).
struct Disk {
    s: store::Store,
    rel: String,
}
static N: AtomicU32 = AtomicU32::new(0);
impl Disk {
    fn new(rec: &NetRec) -> Disk {
        let d = std::env::temp_dir().join(format!("bp-join2-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
        let _ = std::fs::remove_dir_all(&d);
        let disk = Disk { s: store::Store::new(d), rel: format!("net/{}", hex::encode(rec.base.net_id)) };
        disk.s.write_cas(&disk.rel, 0, &seal(&disk.rel, 1, &netrec::encode(rec))).unwrap();
        disk
    }
    /// (plain, generation) as store_read_sealed + the platform's open give it
    fn read(&self) -> (Vec<u8>, u64) {
        let r = self.s.read(&self.rel).unwrap().unwrap();
        (open(&self.rel, r.generation, &r.sealed).expect("the record opens with aad(rel, its header generation)"), r.generation)
    }
    fn rec(&self) -> NetRec {
        netrec::decode(&self.read().0).unwrap()
    }
    fn mine(&self) -> Option<Member> {
        let h = netrec::dac_hash(&joining_node().dac_pub);
        if self.rel.starts_with("mnet/") {
            return MNet::decode(&self.read().0).unwrap().me;
        }
        self.rec().members().unwrap().into_iter().find(|x| x.dac_pub_hash == h)
    }
    /// a member phone's mnet record
    fn new_mnet(x: &MNet) -> Disk {
        let d = std::env::temp_dir().join(format!("bp-join2m-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
        let _ = std::fs::remove_dir_all(&d);
        let disk = Disk { s: store::Store::new(d), rel: format!("mnet/{}", hex::encode(x.net_id)) };
        disk.s.write_cas(&disk.rel, 0, &seal(&disk.rel, 1, &x.encode())).unwrap();
        disk
    }
}
fn seal(rel: &str, g: u64, plain: &[u8]) -> Vec<u8> {
    let mut s = Sha256::digest(store::aad(rel, g)).to_vec();
    s.extend(plain);
    s
}
fn open(rel: &str, g: u64, sealed: &[u8]) -> Option<Vec<u8>> {
    (sealed.len() >= 32 && sealed[..32] == Sha256::digest(store::aad(rel, g))[..]).then(|| sealed[32..].to_vec())
}

#[derive(Clone, Debug)]
enum R {
    Ok(V),
    Err(u64, V),
    /// settings/set: the radio changes, the answer is still an error (helper gone, verdict unknown)
    ErrChanged(u64, V),
    /// no answer at all (the link went away)
    Silent,
    /// the node's own behaviour (for a later entry of a queue)
    Pass,
}

struct Node {
    t: snow::TransportState,
    hh: [u8; 32],
    rx: frame::Reassembler,
    helper: Option<[u8; 32]>,
    got: Vec<String>,
    country: String,
    /// countries asked by settings/set, in order
    sets: Vec<String>,
    get_r: VecDeque<R>,
    set_r: VecDeque<R>,
    join_r: VecDeque<R>,
    info_r: VecDeque<R>,
    /// op/nonce answers in order: Some(code) = refused, None (or none left) = a nonce
    nonce_r: VecDeque<Option<u64>>,
    /// the node is in the network (after a join it accepted)
    in_net: bool,
    /// what the node decrypted: (sae, net_root), and the decoded secrets payload
    secrets: Vec<(String, Vec<u8>)>,
    sec_payloads: Vec<V>,
    /// the join bodies as received (keys 1-3 encoded)
    bodies: Vec<(Vec<u8>, Vec<u8>)>,
}

fn pair(country: &str) -> (Conn, Node) {
    let v = vectors();
    let p: snow::params::NoiseParams = "Noise_NX_25519_ChaChaPoly_SHA256".parse().unwrap();
    let pro = noise::prologue(noise::Mode::Nx, Some("x"));
    let mut r = snow::Builder::new(p).prologue(&pro).unwrap().local_private_key(&h(&v["keys"]["s_node_priv"])).unwrap().build_responder().unwrap();
    let mut i = noise::Initiator::new(noise::Mode::Nx, Some("x"), None).unwrap();
    let mut buf = vec![0u8; 65535];
    r.read_message(&i.msg1().unwrap(), &mut buf).unwrap();
    let n = r.write_message(b"cert", &mut buf).unwrap();
    let (_, s) = i.read_msg2(&buf[..n]).unwrap();
    let hh: [u8; 32] = r.get_handshake_hash().try_into().unwrap();
    let node = Node {
        t: r.into_transport_mode().unwrap(),
        hh,
        rx: frame::Reassembler::new(FL, 8192),
        helper: None,
        got: vec![],
        country: country.into(),
        sets: vec![],
        get_r: VecDeque::new(),
        set_r: VecDeque::new(),
        join_r: VecDeque::new(),
        info_r: VecDeque::new(),
        nonce_r: VecDeque::new(),
        in_net: false,
        secrets: vec![],
        sec_payloads: vec![],
        bodies: vec![],
    };
    (Conn::new(s, FL), node)
}

fn sign1_check(item: &V, label: &[u8], ct: &str) -> Result<V, String> {
    let V::Tag(18, a) = item else { return Err("not tag 18".into()) };
    let V::Array(a) = a.as_ref() else { return Err("not an array".into()) };
    let prot = a[0].as_bytes().ok_or("protected")?;
    let p = cbor::decode(prot).map_err(|e| format!("{e:?}"))?;
    if p.get(3).and_then(|x| x.as_text()) != Some(ct) {
        return Err(format!("protected header {p:?}"));
    }
    let payload = a[2].as_bytes().ok_or("payload")?;
    let s = a[3].as_bytes().ok_or("sig")?;
    let tbs = cbor::encode(&V::Array(vec![V::Text("Signature1".into()), V::Bytes(prot.to_vec()), V::Bytes(label.to_vec()), V::Bytes(payload.to_vec())]));
    p256::ecdsa::VerifyingKey::from_sec1_bytes(&pub_of(&key(ADMIN)))
        .unwrap()
        .verify(&tbs, &p256::ecdsa::Signature::from_slice(s).map_err(|e| e.to_string())?)
        .map_err(|_| format!("{ct}: admin signature"))?;
    cbor::decode(payload).map_err(|e| format!("{e:?}"))
}

impl Node {
    fn owner_op(&mut self, verb: &str, body: &V) -> Result<V, String> {
        let V::Map(e) = body else { return Err("body".into()) };
        let wo = V::Map(e.iter().filter(|(k, _)| *k != V::Uint(31)).cloned().collect());
        let op = body.get(31).ok_or("no owner-op")?;
        if op.get(1).and_then(|x| x.as_text()) != Some(verb) {
            return Err("owner-op verb".into());
        }
        let s: [u8; 64] = op.get(2).and_then(|x| x.as_bytes()).ok_or("sig")?.try_into().map_err(|_| "sig len")?;
        let helper = self.helper.take().ok_or("nonce_helper used twice / never issued")?;
        let input = sig::owner_op_input(&self.hh, &helper, verb, &wo).unwrap();
        p256::ecdsa::VerifyingKey::from_sec1_bytes(&pub_of(&key(OWNER)))
            .unwrap()
            .verify(&input, &p256::ecdsa::Signature::from_slice(&s).unwrap())
            .map_err(|_| "owner-op signature")?;
        Ok(wo)
    }

    /// what a real node checks (F2, F4), plus decrypting net_secrets with this node's own ECDH key
    fn check_join(&mut self, body: &V) -> Result<(), String> {
        let wo = self.owner_op("network/join", body)?;
        let cfg = sign1_check(wo.get(1).ok_or("1")?, b"batman-netcfg-v1", "batman/netcfg")?;
        sign1_check(wo.get(2).ok_or("2")?, b"batman-members-v1", "batman/members")?;
        let sec = sign1_check(wo.get(3).ok_or("3")?, b"batman-secrets-v1", "batman/secrets")?;
        self.bodies.push((cbor::encode(wo.get(1).unwrap()), cbor::encode(wo.get(2).unwrap())));
        // wtxn.go:127-131: key 3 must be SHA-256 of THIS node's DAC pub
        if sec.get(3).and_then(|x| x.as_bytes()) != Some(&netrec::dac_hash(&joining_node().dac_pub)[..]) {
            return Err("secrets: target hash".into());
        }
        // the KDF context takes the secrets' own net_id / version (the node does not compare them with the netcfg, F4)
        let net_id = sec.get(1).and_then(|x| x.as_bytes()).ok_or("net_id")?.to_vec();
        let version = sec.get(2).and_then(|x| x.as_uint()).ok_or("version")? as u32;
        let V::Tag(96, enc) = sec.get(4).ok_or("4")? else { return Err("not tag 96".into()) };
        let V::Array(a) = enc.as_ref() else { return Err("enc".into()) };
        let iv = a[1].get(5).and_then(|x| x.as_bytes()).ok_or("iv")?.to_vec();
        let ct = a[2].as_bytes().ok_or("ct")?.to_vec();
        let V::Array(rec) = &a[3] else { return Err("recipients".into()) };
        let V::Array(r0) = &rec[0] else { return Err("r0".into()) };
        let ck = nint(&r0[1], 0).ok_or("ephemeral key")?;
        let mut epk = vec![4u8];
        epk.extend(nint(ck, 1).and_then(|x| x.as_bytes()).ok_or("x")?);
        epk.extend(nint(ck, 2).and_then(|x| x.as_bytes()).ok_or("y")?);
        let node_priv = p256::SecretKey::from_slice(&[0x42; 32]).unwrap();
        let z = p256::ecdh::diffie_hellman(node_priv.to_nonzero_scalar(), p256::PublicKey::from_sec1_bytes(&epk).unwrap().as_affine());
        let mut party_v = net_id.clone();
        party_v.extend(version.to_be_bytes());
        let rec_prot = cbor::encode(&V::Map(vec![(V::Uint(1), V::Nint(24))]));
        let ctx = cbor::encode(&V::Array(vec![
            V::Uint(24),
            V::Array(vec![V::Null, V::Null, V::Null]),
            V::Array(vec![V::Bytes(netrec::dac_hash(&joining_node().dac_pub).to_vec()), V::Null, V::Null]),
            V::Array(vec![V::Uint(256), V::Bytes(rec_prot), V::Bytes(party_v)]),
        ]));
        let cek = kdf::hkdf32(z.raw_secret_bytes().as_slice(), &ctx);
        let aad = cbor::encode(&V::Array(vec![
            V::Text("Encrypt".into()),
            V::Bytes(cbor::encode(&V::Map(vec![(V::Uint(1), V::Uint(24))]))),
            V::Bytes(b"batman-secrets-v1".to_vec()),
        ]));
        let pt = chacha20poly1305::ChaCha20Poly1305::new(chacha20poly1305::Key::from_slice(&cek))
            .decrypt(chacha20poly1305::Nonce::from_slice(&iv), Payload { msg: &ct, aad: &aad })
            .map_err(|_| "net_secrets does not decrypt at the joining node")?;
        let plain = cbor::decode(&pt).map_err(|e| format!("{e:?}"))?;
        self.secrets.push((plain.get(1).and_then(|x| x.as_text()).ok_or("sae")?.into(), plain.get(2).and_then(|x| x.as_bytes()).ok_or("root")?.to_vec()));
        self.sec_payloads.push(sec);
        let _ = cfg;
        Ok(())
    }

    fn on(&mut self, frames: &[Vec<u8>]) -> Vec<Vec<u8>> {
        let mut msg = None;
        for f in frames {
            msg = self.rx.push(f).unwrap();
        }
        let Some(msg) = msg else { return vec![] };
        let mut buf = vec![0u8; 65535];
        let n = self.t.read_message(&msg, &mut buf).unwrap();
        let req = cbor::decode(&buf[..n]).unwrap();
        let id = req.get(1).and_then(|x| x.as_uint()).unwrap();
        let verb = req.get(2).and_then(|x| x.as_text()).unwrap().to_string();
        let body = req.get(3).unwrap().clone();
        self.got.push(verb.clone());
        let country = |c: &str| m(vec![(2, V::Text(c.into()))]);
        let r = match verb.as_str() {
            "op/nonce" => match self.nonce_r.pop_front().flatten() {
                Some(c) => R::Err(c, m(vec![])),
                None => {
                    self.helper = Some([0x6d; 32]);
                    R::Ok(m(vec![(1, V::Bytes(vec![0x6d; 32]))]))
                }
            },
            "settings/get" => self.get_r.pop_front().filter(|x| !matches!(x, R::Pass)).unwrap_or_else(|| R::Ok(country(&self.country))),
            "settings/set" => {
                let wo = self.owner_op("settings/set", &body).unwrap_or_else(|e| panic!("the node would refuse settings/set: {e}"));
                let want = wo.get(2).and_then(|x| x.as_text()).unwrap().to_string();
                self.sets.push(want.clone());
                match self.set_r.pop_front().filter(|x| !matches!(x, R::Pass)) {
                    None => {
                        self.country = want;
                        R::Ok(country(&self.country))
                    }
                    Some(R::ErrChanged(c, d)) => {
                        self.country = want;
                        R::Err(c, d)
                    }
                    Some(x) => x,
                }
            }
            "network/join" => {
                if let Err(why) = self.check_join(&body) {
                    panic!("the node would refuse the join: {why}");
                }
                match self.join_r.pop_front().filter(|x| !matches!(x, R::Pass)) {
                    None => {
                        self.in_net = true;
                        R::Ok(m(vec![(1, V::Uint(0))]))
                    }
                    Some(x) => x,
                }
            }
            "info" => self.info_r.pop_front().filter(|x| !matches!(x, R::Pass)).unwrap_or_else(|| R::Ok(if self.in_net { info_applied(false) } else { info_absent(false) })),
            _ => R::Err(2, m(vec![])),
        };
        let reply = match r {
            R::Ok(b) => m(vec![(1, V::Uint(id)), (3, b), (4, V::Uint(0))]),
            R::Err(c, d) | R::ErrChanged(c, d) => m(vec![(1, V::Uint(id)), (4, V::Uint(c)), (5, d)]),
            R::Silent => return vec![],
            R::Pass => unreachable!(),
        };
        let n = self.t.write_message(&cbor::encode(&reply), &mut buf).unwrap();
        frame::split(&buf[..n], FL).unwrap()
    }
}

fn info_applied(save_pending: bool) -> V {
    m(vec![(9, V::Uint(1)), (10, V::Bytes(NET_ID.to_vec())), (11, V::Bool(save_pending))])
}
fn info_absent(in_progress: bool) -> V {
    m(vec![(11, V::Bool(in_progress))])
}
fn info_other() -> V {
    m(vec![(9, V::Uint(1)), (10, V::Bytes(vec![0x99; 16])), (11, V::Bool(false))])
}

#[derive(Default)]
struct Run {
    /// None = the node went silent (link lost)
    end: Option<End>,
    /// (have, want) the user was asked about
    asked: Vec<(String, String)>,
    /// the node's verbs at each record write
    writes: Vec<Vec<String>>,
    /// which record each write was: "net" / "mnet"
    kinds: Vec<&'static str>,
    admin_signs: usize,
}

struct Opts {
    yes: bool,
    /// the n-th (0-based) admin signature of the run fails
    admin_fail_at: Option<usize>,
    /// the n-th (0-based) owner signature of the run fails
    owner_fail_at: Option<usize>,
    /// a write elsewhere just before the n-th (0-based) PersistNet of this run
    bump_before: Option<usize>,
}
const YES: Opts = Opts { yes: true, admin_fail_at: None, owner_fail_at: None, bump_before: None };

fn input(disk: &Disk, node: Option<Verified>) -> Input {
    let (plain, g) = disk.read();
    Input {
        record_plain: plain,
        record_gen: g,
        node,
        node_name: "node-2233".into(),
        owner_pub: pub_of(&key(OWNER)),
        owner_enc_pub: pub_of(&key(0x22)),
        admin_pub: pub_of(&key(ADMIN)),
        member: false,
        removed_confirmed: false,
    }
}

fn drive(node: &mut Node, disk: &Disk, j: Join2, a: Action, o: &Opts) -> Run {
    drive_keep(node, disk, j, a, o).0
}

/// `drive`, and the flow afterwards (remove-member: `node_behind`)
fn drive_keep(node: &mut Node, disk: &Disk, mut j: Join2, mut a: Action, o: &Opts) -> (Run, Join2) {
    let mut run = Run::default();
    let mut admin = 0;
    let mut owner = 0;
    loop {
        // which write the flow asked for (the action's own variant, not the disk it lands on)
        let mnet_write = matches!(a, Action::PersistMnet { .. });
        a = match a {
            Action::SignAdmin { tbs } => {
                assert_eq!(tbs[0], 0x84, "a COSE Sig_structure");
                let der = if o.admin_fail_at == Some(admin) { vec![] } else { signed(ADMIN, &tbs) };
                admin += 1;
                run.admin_signs += 1;
                j.signed(&der).expect("an action after the admin signature")
            }
            Action::SignOwner { input } => {
                assert!(input.starts_with(b"batman-owner-op-v1"));
                let der = if o.owner_fail_at == Some(owner) { vec![] } else { signed(OWNER, &input) };
                owner += 1;
                j.signed(&der).unwrap()
            }
            Action::ConfirmCountry { have, want } => {
                run.asked.push((have, want));
                j.country_confirmed(o.yes).unwrap()
            }
            Action::PersistNet { net_id, plain, expected_gen } | Action::PersistMnet { net_id, plain, expected_gen } => {
                assert_eq!(net_id, NET_ID);
                run.kinds.push(if mnet_write { "mnet" } else { "net" });
                if o.bump_before == Some(run.writes.len()) {
                    let (p, g) = disk.read();
                    disk.s.write_cas(&disk.rel, g, &seal(&disk.rel, g + 1, &p)).unwrap();
                }
                run.writes.push(node.got.clone());
                match disk.s.write_cas(&disk.rel, expected_gen, &seal(&disk.rel, expected_gen + 1, &plain)) {
                    Ok(g) => {
                        assert_eq!(g, expected_gen + 1);
                        j.net_persisted().unwrap()
                    }
                    Err(store::Error::Stale { .. }) => j.persist_failed(None).unwrap(),
                    Err(e) => panic!("{e:?}"),
                }
            }
            Action::Write(f) => {
                let back = node.on(&f);
                if back.is_empty() {
                    return (run, j); // silence: the caller's timeout / link loss
                }
                let mut next = None;
                for x in &back {
                    next = j.on_frame(x).or(next);
                }
                next.expect("an action after the node's reply")
            }
            Action::Done(e) => {
                run.end = Some(e);
                return (run, j);
            }
        };
    }
}

fn join(disk: &Disk, node: &mut Node, conn: Conn, o: &Opts) -> Run {
    let (j, a) = Join2::start(conn, input(disk, Some(joining_node())));
    drive(node, disk, j, a, o)
}

// ---- T1 -----------------------------------------------------------------------------------------------------------

#[test]
fn t1_second_node_joins_with_the_records_netcfg() {
    let rec = applied_record("US");
    let disk = Disk::new(&rec);
    let (c, mut n) = pair("US");
    let run = join(&disk, &mut n, c, &YES);
    assert_eq!(run.end, Some(End::Applied { country_unverified: false, save_pending: false }));
    assert_eq!(n.got, ["settings/get", "op/nonce", "network/join"]);
    assert_eq!(run.writes[0], ["settings/get"], "the joining entry lands before op/nonce / network/join");
    // body key 1 / 2 = the record's signed objects, byte for byte
    assert_eq!(n.bodies[0].0, rec.base.netcfg);
    assert_eq!(n.bodies[0].1, rec.base.members);
    // the joining node decrypted the record's SAE / net_root with its own ECDH key
    assert_eq!(n.secrets, [(SAE.to_string(), vec![0x77; 32])]);
    // net_id / version in net_secrets = the netcfg's (the node would not catch a mismatch, F4)
    let cfg = rec.netcfg().unwrap();
    assert_eq!(n.sec_payloads[0].get(1).and_then(|x| x.as_bytes()), Some(&cfg.net_id[..]));
    assert_eq!(n.sec_payloads[0].get(2).and_then(|x| x.as_uint()), Some(cfg.version as u64));
    // the record: first node derived + this node applied, with its device id; no secrets in the entry
    let after = disk.rec();
    let l = after.list.clone().unwrap();
    assert_eq!(l.len(), 2);
    assert_eq!(l[0].dac_pub_hash, netrec::dac_hash(&pub_of(&key(0x55))));
    assert_eq!(l[1].state, MemberState::Applied);
    assert_eq!(l[1].device_id.as_deref(), Some("aabbccddeeff00112233"));
    assert_eq!(l[1].prev_country, None);
    assert_eq!(after.base, rec.base, "keys 1-10 unchanged");
}

// ---- T2 -----------------------------------------------------------------------------------------------------------

fn refused(rec: &NetRec, node: Option<Verified>) -> (Run, Vec<String>, u64) {
    let disk = Disk::new(rec);
    let (c, mut n) = pair("US");
    let (j, a) = Join2::start(c, input(&disk, node));
    let run = drive(&mut n, &disk, j, a, &YES);
    (run, n.got, disk.read().1)
}

#[test]
fn t2_a_record_not_applied() {
    let (run, got, g) = refused(&record("US", &[pub_of(&key(ADMIN))], "pending", None), Some(joining_node()));
    assert_eq!(run.end, Some(End::Refused(Pre::NotApplied)));
    assert!(got.is_empty() && run.writes.is_empty() && g == 1, "nothing written or sent");
}

#[test]
fn t2_a_record_does_not_decode() {
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair("US");
    let mut inp = input(&disk, Some(joining_node()));
    inp.record_plain = vec![0xa1, 0x01];
    let (j, a) = Join2::start(c, inp);
    let run = drive(&mut n, &disk, j, a, &YES);
    assert_eq!(run.end, Some(End::Refused(Pre::Record)));
    assert!(n.got.is_empty() && run.writes.is_empty());
}

#[test]
fn t2_b_no_verified_node_cert() {
    let (run, got, g) = refused(&applied_record("US"), None);
    assert_eq!(run.end, Some(End::Refused(Pre::NotVerified)));
    assert!(got.is_empty() && run.writes.is_empty() && g == 1);
}

#[test]
fn t2_c_phone_not_an_admin_of_the_netcfg() {
    let (run, got, g) = refused(&record("US", &[pub_of(&key(0x67))], "applied", None), Some(joining_node()));
    assert_eq!(run.end, Some(End::Refused(Pre::NotAdmin)));
    assert!(got.is_empty() && run.writes.is_empty() && g == 1);
}

fn others(n: usize) -> Vec<Member> {
    (0..n).map(|i| member(0x80 + i as u8, 0x43, &format!("n{i}"), MemberState::Applied)).collect()
}

#[test]
fn t2_d_sixteen_members_without_this_node() {
    let (run, got, g) = refused(&record("US", &[pub_of(&key(ADMIN))], "applied", Some(others(16))), Some(joining_node()));
    assert_eq!(run.end, Some(End::Refused(Pre::Full)));
    assert!(got.is_empty() && run.writes.is_empty() && g == 1);
    // an older entry of the same node does not count: 15 others + this node's old entry -> it may join (replacing it)
    let mut l = others(15);
    l.push(member(0x77, 0x42, "old", MemberState::Applied));
    let rec = record("US", &[pub_of(&key(ADMIN))], "applied", Some(l));
    let disk = Disk::new(&rec);
    let (c, mut n) = pair("US");
    assert_eq!(join(&disk, &mut n, c, &YES).end, Some(End::Applied { country_unverified: false, save_pending: false }));
    assert_eq!(disk.rec().list.unwrap().len(), 16, "replaced, not added");
}

// ---- T3 / T4: the join reply ------------------------------------------------------------------------------------

/// a join where the node's country was changed (JP -> US) first, so a definite failure has something to put back
fn join_with(country: &str, set_up: impl FnOnce(&mut Node)) -> (Run, Node, Disk) {
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair(country);
    set_up(&mut n);
    let run = join(&disk, &mut n, c, &YES);
    (run, n, disk)
}

#[test]
fn t3_zero_is_applied() {
    let (run, _, disk) = join_with("JP", |_| {});
    assert_eq!(run.end, Some(End::Applied { country_unverified: false, save_pending: false }));
    let me = disk.mine().unwrap();
    assert_eq!((me.state, me.prev_country), (MemberState::Applied, None), "applied clears prev_country");
}

#[test]
fn t3_three_resends_once_with_new_secrets() {
    let (run, n, _) = join_with("US", |n| n.join_r.push_back(R::Err(3, m(vec![]))));
    assert_eq!(run.end, Some(End::Applied { country_unverified: false, save_pending: false }));
    assert_eq!(n.got, ["settings/get", "op/nonce", "network/join", "op/nonce", "network/join"]);
    assert_eq!(n.secrets.len(), 2);
    assert_ne!(n.sec_payloads[0], n.sec_payloads[1], "secrets made afresh for the resend");
    let (run, n, disk) = join_with("US", |n| {
        n.join_r.push_back(R::Err(3, m(vec![])));
        n.join_r.push_back(R::Err(3, m(vec![])));
    });
    assert_eq!(run.end, Some(End::Joining(Keep::TwiceRefused)));
    assert_eq!(n.got.iter().filter(|v| *v == "network/join").count(), 2, "never a third");
    assert_eq!(disk.mine().unwrap().state, MemberState::Joining);
}

#[test]
fn t3_four_puts_the_country_back_then_deletes() {
    let (run, n, disk) = join_with("JP", |n| n.join_r.push_back(R::Err(4, m(vec![]))));
    assert_eq!(run.end, Some(End::Failed(Fail::Rejected, Revert::Reverted { country: "JP".into() })));
    assert_eq!(n.sets, ["US", "JP"]);
    assert!(disk.mine().is_none());
    // no country change -> the entry goes directly
    let (run, n, disk) = join_with("US", |n| n.join_r.push_back(R::Err(4, m(vec![]))));
    assert_eq!(run.end, Some(End::Failed(Fail::Rejected, Revert::NoChange)));
    assert!(n.sets.is_empty() && disk.mine().is_none());
}

#[test]
fn t3_seven_reads_info_applied() {
    let (run, n, disk) = join_with("JP", |n| {
        n.join_r.push_back(R::Err(7, m(vec![])));
        n.info_r.push_back(R::Ok(info_applied(false)));
    });
    assert_eq!(run.end, Some(End::Applied { country_unverified: false, save_pending: false }));
    assert_eq!(n.got.last().map(String::as_str), Some("info"));
    assert_eq!(disk.mine().unwrap().state, MemberState::Applied);
}

#[test]
fn t3_seven_not_applied_keeps_joining_and_the_country() {
    for detail in [m(vec![]), m(vec![(3, V::Text("outcome unknown".into()))])] {
        let (run, n, disk) = join_with("JP", |n| {
            n.join_r.push_back(R::Err(7, detail.clone()));
            n.info_r.push_back(R::Ok(info_absent(false)));
        });
        assert_eq!(run.end, Some(End::Joining(Keep::Unclear7)));
        assert_eq!(n.sets, ["US"], "7 never puts the country back");
        let me = disk.mine().unwrap();
        assert_eq!((me.state, me.prev_country.as_deref()), (MemberState::Joining, Some("JP")));
    }
}

#[test]
fn t3_eleven_not_applied_puts_the_country_back() {
    let (run, n, disk) = join_with("JP", |n| {
        n.join_r.push_back(R::Err(11, m(vec![])));
        n.info_r.push_back(R::Ok(info_absent(false)));
    });
    assert_eq!(run.end, Some(End::Failed(Fail::NotApplied(11), Revert::Reverted { country: "JP".into() })));
    assert_eq!(n.got[n.got.len() - 5..], ["network/join", "info", "settings/get", "op/nonce", "settings/set"]);
    assert_eq!(n.sets, ["US", "JP"]);
    assert!(disk.mine().is_none());
}

#[test]
fn t3_eleven_in_progress_or_unknown_keeps_joining() {
    for info in [R::Ok(info_absent(true)), R::Ok(m(vec![])), R::Err(12, m(vec![]))] {
        let (run, n, disk) = join_with("JP", |n| {
            n.join_r.push_back(R::Err(11, m(vec![])));
            n.info_r.push_back(info.clone());
        });
        assert_eq!(run.end, Some(End::Joining(Keep::Unclear)), "{info:?}");
        assert_eq!(n.sets, ["US"]);
        assert_eq!(disk.mine().unwrap().prev_country.as_deref(), Some("JP"));
    }
}

#[test]
fn t3_lost_reply_keeps_joining_and_the_country() {
    let (run, n, disk) = join_with("JP", |n| n.join_r.push_back(R::Silent));
    assert_eq!(run.end, None);
    assert_eq!(n.sets, ["US"]);
    let me = disk.mine().unwrap();
    assert_eq!((me.state, me.prev_country.as_deref()), (MemberState::Joining, Some("JP")));
}

#[test]
fn t4_five_same_network_is_applied() {
    let (run, n, disk) = join_with("US", |n| {
        n.join_r.push_back(R::Err(5, m(vec![])));
        n.info_r.push_back(R::Ok(info_applied(true)));
    });
    assert_eq!(run.end, Some(End::Applied { country_unverified: false, save_pending: true }));
    assert_eq!(n.got.last().map(String::as_str), Some("info"));
    assert_eq!(disk.mine().unwrap().state, MemberState::Applied);
}

#[test]
fn t4_five_other_network_puts_the_country_back() {
    let (run, n, disk) = join_with("JP", |n| {
        n.join_r.push_back(R::Err(5, m(vec![])));
        n.info_r.push_back(R::Ok(info_other()));
    });
    assert_eq!(run.end, Some(End::Failed(Fail::OtherNetwork, Revert::Reverted { country: "JP".into() })));
    assert_eq!(n.sets, ["US", "JP"]);
    assert!(disk.mine().is_none());
    // key 10 absent -> stays joining
    let (run, n, _) = join_with("JP", |n| {
        n.join_r.push_back(R::Err(5, m(vec![])));
        n.info_r.push_back(R::Ok(info_absent(false)));
    });
    assert_eq!(run.end, Some(End::Joining(Keep::Unclear)));
    assert_eq!(n.sets, ["US"]);
}

// ---- T7: the country -------------------------------------------------------------------------------------------

#[test]
fn t7_different_country_writes_prev_country_then_sets_the_netcfg_country() {
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair("JP");
    let run = join(&disk, &mut n, c, &YES);
    assert_eq!(run.asked, [("JP".to_string(), "US".to_string())]);
    assert_eq!(run.writes[0], ["settings/get"], "prev_country lands before settings/set");
    assert_eq!(n.sets, ["US"]);
    assert_eq!(n.got, ["settings/get", "op/nonce", "settings/set", "op/nonce", "network/join"]);
    assert!(matches!(run.end, Some(End::Applied { .. })));
}

#[test]
fn t7_user_declines() {
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair("JP");
    let run = join(&disk, &mut n, c, &Opts { yes: false, ..YES });
    assert_eq!(run.end, Some(End::Declined { have: "JP".into(), want: "US".into() }));
    assert_eq!(n.got, ["settings/get"]);
    assert!(run.writes.is_empty() && disk.read().1 == 1);
}

#[test]
fn t7_not_applied_after_a_country_change_sets_it_back() {
    let (run, n, _) = join_with("JP", |n| {
        n.join_r.push_back(R::Err(10, m(vec![])));
        n.info_r.push_back(R::Ok(info_absent(false)));
    });
    assert_eq!(run.end, Some(End::Failed(Fail::NotApplied(10), Revert::Reverted { country: "JP".into() })));
    assert_eq!(n.sets, ["US", "JP"]);
}

#[test]
fn t7_set_refused_with_14_or_20_restores_the_entry() {
    for (code, reason) in [(11, 14), (6, 20)] {
        let (run, n, disk) = join_with("JP", |n| n.set_r.push_back(R::Err(code, m(vec![(2, V::Uint(reason))]))));
        assert_eq!(run.end, Some(End::CountryRefused { code, reason }));
        assert_eq!(n.sets, ["US"], "no settings/set back to the original");
        assert!(!n.got.contains(&"network/join".to_string()));
        assert!(disk.mine().is_none(), "no entry before -> none after");
    }
    // an applied entry of the same node (re-flashed) goes back to what it was
    let mut l = vec![member(0x77, 0x42, "old", MemberState::Applied)];
    l[0].device_id = Some("x".into());
    let disk = Disk::new(&record("US", &[pub_of(&key(ADMIN))], "applied", Some(l.clone())));
    let (c, mut n) = pair("JP");
    n.set_r.push_back(R::Err(11, m(vec![(2, V::Uint(14))])));
    assert!(matches!(join(&disk, &mut n, c, &YES).end, Some(End::CountryRefused { .. })));
    assert_eq!(disk.rec().list.unwrap(), l);
}

#[test]
fn t7_unclear_set_answer_reads_the_country() {
    let unclear = [R::Err(11, m(vec![])), R::Err(11, m(vec![(2, V::Uint(13))])), R::Err(7, m(vec![])), R::Err(7, m(vec![(3, V::Text("outcome unknown".into()))]))];
    for r in unclear.clone() {
        // the radio did change (US) -> go on
        let r2 = match r.clone() {
            R::Err(c, d) => R::ErrChanged(c, d),
            x => x,
        };
        let (run, n, _) = join_with("JP", |n| n.set_r.push_back(r2));
        assert!(matches!(run.end, Some(End::Applied { .. })), "{r:?} + US");
        assert_eq!(n.got[3], "settings/get");
        // still JP (maybe the old value) -> keep the entry and prev_country, stop
        let (run, n, disk) = join_with("JP", |n| n.set_r.push_back(r.clone()));
        assert_eq!(run.end, Some(End::Joining(Keep::CountryUnknown)), "{r:?} + JP");
        assert!(!n.got.contains(&"network/join".to_string()));
        assert_eq!(disk.mine().unwrap().prev_country.as_deref(), Some("JP"));
        // settings/get unreadable -> same
        let (run, _, disk) = join_with("JP", |n| {
            n.set_r.push_back(r.clone());
            n.get_r.push_back(R::Ok(country_of("JP")));
            n.get_r.push_back(R::Err(12, m(vec![])));
        });
        assert_eq!(run.end, Some(End::Joining(Keep::CountryUnknown)));
        assert_eq!(disk.mine().unwrap().prev_country.as_deref(), Some("JP"));
    }
    // the link went away after settings/set -> nothing more; the entry and prev_country stay
    let (run, _, disk) = join_with("JP", |n| n.set_r.push_back(R::Silent));
    assert_eq!(run.end, None);
    assert_eq!(disk.mine().unwrap().prev_country.as_deref(), Some("JP"));
}

fn country_of(c: &str) -> V {
    m(vec![(2, V::Text(c.into()))])
}

#[test]
fn t7_revert_fails_keeps_the_entry_and_prev_country() {
    let (run, n, disk) = join_with("JP", |n| {
        n.join_r.push_back(R::Err(4, m(vec![])));
        n.set_r.push_back(R::Pass); // the first set (to US) works
        n.set_r.push_back(R::Err(11, m(vec![]))); // putting JP back fails (e.g. EState)
    });
    assert_eq!(n.sets, ["US", "JP"]);
    assert_eq!(run.end, Some(End::Failed(Fail::Rejected, Revert::NotReverted { now: "US".into(), was: "JP".into() })));
    let me = disk.mine().unwrap();
    assert_eq!((me.state, me.prev_country.as_deref()), (MemberState::Joining, Some("JP")));
}

#[test]
fn t7_revert_skips_set_when_already_original() {
    let (run, n, disk) = join_with("JP", |n| {
        n.join_r.push_back(R::Err(4, m(vec![])));
        n.get_r.push_back(R::Ok(country_of("JP"))); // step 3
        n.get_r.push_back(R::Ok(country_of("JP"))); // before putting back: already JP (e.g. setkey restored it)
    });
    assert_eq!(run.end, Some(End::Failed(Fail::Rejected, Revert::Reverted { country: "JP".into() })));
    assert_eq!(n.sets, ["US"], "no settings/set when it already is the original");
    assert!(disk.mine().is_none());
}

#[test]
fn t7_lost_after_join_does_not_revert() {
    let (run, n, disk) = join_with("JP", |n| n.join_r.push_back(R::Silent));
    assert_eq!(run.end, None);
    assert_eq!(n.sets, ["US"]);
    assert_eq!(disk.mine().unwrap().prev_country.as_deref(), Some("JP"));
}

#[test]
fn t7_new_session_from_the_store_still_reverts() {
    // session 1: JP -> US, the join answer is unclear (7) and stays joining
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair("JP");
    n.join_r.push_back(R::Err(7, m(vec![])));
    n.info_r.push_back(R::Ok(info_absent(true)));
    assert_eq!(join(&disk, &mut n, c, &YES).end, Some(End::Joining(Keep::Unclear7)));
    // session 2 ("繼續加入"): a new connection, the record read back from the store only; NotApplied -> back to JP
    let (c2, mut n2) = pair("US");
    n2.join_r.push_back(R::Err(11, m(vec![])));
    n2.info_r.push_back(R::Ok(info_absent(false)));
    let run = join(&disk, &mut n2, c2, &YES);
    assert!(run.asked.is_empty(), "the country is already the netcfg's: not changed again");
    assert_eq!(run.end, Some(End::Failed(Fail::NotApplied(11), Revert::Reverted { country: "JP".into() })));
    assert_eq!(n2.sets, ["JP"]);
    assert!(disk.mine().is_none());
}

#[test]
fn t7_p2_goes_on_unverified_other_errors_stop() {
    let (run, n, _) = join_with("JP", |n| n.get_r.push_back(R::Err(6, m(vec![(1, V::Text("settings/get".into()))]))));
    assert_eq!(run.end, Some(End::Applied { country_unverified: true, save_pending: false }));
    assert!(n.sets.is_empty());
    for (code, d) in [(6, m(vec![(1, V::Text("settings/get".into())), (2, V::Uint(20))])), (12, m(vec![])), (6, m(vec![(1, V::Text("status".into()))]))] {
        let (run, n, disk) = join_with("JP", |n| n.get_r.push_back(R::Err(code, d.clone())));
        assert!(matches!(run.end, Some(End::SettingsError(_))), "{code} {d:?}");
        assert_eq!(n.got, ["settings/get"]);
        assert_eq!(disk.read().1, 1, "nothing written");
    }
}

// ---- T8 -----------------------------------------------------------------------------------------------------------

#[test]
fn t8_admin_signature_fails_before_any_write_or_country_change() {
    for country in ["US", "JP"] {
        let disk = Disk::new(&applied_record("US"));
        let (c, mut n) = pair(country);
        let run = join(&disk, &mut n, c, &Opts { admin_fail_at: Some(0), ..YES });
        assert_eq!(run.end, Some(End::AdminSignFailed), "{country}");
        assert!(run.writes.is_empty(), "{country}: nothing written");
        assert!(n.sets.is_empty() && !n.got.contains(&"settings/set".to_string()), "{country}: country untouched");
        assert!(!n.got.contains(&"network/join".to_string()));
        assert_eq!(disk.read().1, 1);
    }
}

// ---- T10 ----------------------------------------------------------------------------------------------------------

#[test]
fn t10_record_changed_after_reading_stops_the_join() {
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair("US");
    let run = join(&disk, &mut n, c, &Opts { bump_before: Some(0), ..YES });
    assert_eq!(run.end, Some(End::PersistFailed { applied: false, error: None }));
    assert!(!n.got.contains(&"network/join".to_string()) && !n.got.contains(&"op/nonce".to_string()), "nothing sent");
    assert!(disk.mine().is_none());
    // the applied write losing its race is recoverable (the node did apply)
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair("US");
    let run = join(&disk, &mut n, c, &Opts { bump_before: Some(1), ..YES });
    assert_eq!(run.end, Some(End::PersistFailed { applied: true, error: None }));
}

#[test]
fn t10_each_write_chains_the_generation() {
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair("JP");
    let run = join(&disk, &mut n, c, &YES);
    assert!(matches!(run.end, Some(End::Applied { .. })));
    // joining+prev (2), joining (3), applied (4): each opened with aad(rel, its generation)
    assert_eq!(run.writes.len(), 3);
    assert_eq!(disk.read().1, 4);
}

// ---- code review round 1 ----------------------------------------------------------------------------------------

#[test]
fn t8_resend_signature_failure_is_unclear_not_nothing_done() {
    // reply 3 -> the resend's admin signature fails: by then the entry (and the country) changed -> keep joining
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair("JP");
    n.join_r.push_back(R::Err(3, m(vec![])));
    let run = join(&disk, &mut n, c, &Opts { admin_fail_at: Some(1), ..YES });
    assert_eq!(run.end, Some(End::Joining(Keep::Unclear)));
    assert_eq!(n.sets, ["US"]);
    let me = disk.mine().unwrap();
    assert_eq!((me.state, me.prev_country.as_deref()), (MemberState::Joining, Some("JP")));
}

#[test]
fn t7_nonce_refused_before_settings_set_restores_the_entry() {
    let (run, n, disk) = join_with("JP", |n| n.nonce_r.push_back(Some(12)));
    assert_eq!(run.end, Some(End::Joining(Keep::NonceRefused(12))));
    assert!(n.sets.is_empty() && !n.got.contains(&"settings/set".to_string()));
    assert!(disk.mine().is_none(), "no entry before -> none after");
    assert_eq!(n.got, ["settings/get", "op/nonce"]);
}

#[test]
fn t3_nonce_refused_before_join_is_a_definite_failure() {
    // country changed first -> put back, then the entry goes
    let (run, n, disk) = join_with("JP", |n| {
        n.nonce_r.push_back(None);
        n.nonce_r.push_back(Some(12));
    });
    assert_eq!(run.end, Some(End::Failed(Fail::NotSent(12), Revert::Reverted { country: "JP".into() })));
    assert_eq!(n.sets, ["US", "JP"]);
    assert!(!n.got.contains(&"network/join".to_string()));
    assert!(disk.mine().is_none());
    // country never changed -> the entry goes directly
    let (run, n, disk) = join_with("US", |n| n.nonce_r.push_back(Some(12)));
    assert_eq!(run.end, Some(End::Failed(Fail::NotSent(12), Revert::NoChange)));
    assert!(n.sets.is_empty());
    assert!(disk.mine().is_none());
}

#[test]
fn t7_nonce_refused_before_revert_keeps_the_entry_and_prev_country() {
    let (run, n, disk) = join_with("JP", |n| {
        n.join_r.push_back(R::Err(4, m(vec![])));
        n.nonce_r.extend([None, None, Some(12)]);
    });
    assert_eq!(run.end, Some(End::Failed(Fail::Rejected, Revert::NotReverted { now: "US".into(), was: "JP".into() })));
    assert_eq!(n.sets, ["US"]);
    let me = disk.mine().unwrap();
    assert_eq!((me.state, me.prev_country.as_deref()), (MemberState::Joining, Some("JP")));
}

// ---- code review round 2 ----------------------------------------------------------------------------------------

#[test]
fn t3_nonce_busy_before_join_keeps_entry_and_prev_country() {
    // run 1: JP -> US, the join answer is unclear (7) and stays joining
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair("JP");
    n.join_r.push_back(R::Err(7, m(vec![])));
    n.info_r.push_back(R::Ok(info_absent(true)));
    assert_eq!(join(&disk, &mut n, c, &YES).end, Some(End::Joining(Keep::Unclear7)));
    // run 2 ("繼續加入"): op/nonce answers 7 (busy with the previous apply) -> outcome unknown, nothing changes
    let (c2, mut n2) = pair("US");
    n2.nonce_r.push_back(Some(7));
    let run = join(&disk, &mut n2, c2, &YES);
    assert_eq!(run.end, Some(End::Joining(Keep::Unclear7)));
    assert!(n2.sets.is_empty(), "no revert");
    let me = disk.mine().unwrap();
    assert_eq!((me.state, me.prev_country.as_deref()), (MemberState::Joining, Some("JP")));
}

fn with_mine(country_prev: Option<&str>, state: MemberState) -> (NetRec, Member) {
    let mut me = member(0x77, 0x42, "node-old", state);
    me.device_id = Some("old".into());
    me.prev_country = country_prev.map(str::to_string);
    let first = member(0x55, 0x43, "node-0001", MemberState::Applied);
    (record("US", &[pub_of(&key(ADMIN))], "applied", Some(vec![first, me.clone()])), me)
}

#[test]
fn t3_nonce_refused_before_join_brings_back_the_replaced_entry() {
    // a re-flashed applied member: no country change, op/nonce refused -> the applied entry is back
    let (rec, before) = with_mine(None, MemberState::Applied);
    let disk = Disk::new(&rec);
    let (c, mut n) = pair("US");
    n.nonce_r.push_back(Some(12));
    assert_eq!(join(&disk, &mut n, c, &YES).end, Some(End::Failed(Fail::NotSent(12), Revert::NoChange)));
    assert_eq!(disk.mine(), Some(before.clone()));
    // with a country change: put back first, then the applied entry is back
    let disk = Disk::new(&rec);
    let (c, mut n) = pair("JP");
    n.nonce_r.extend([None, Some(12)]);
    assert_eq!(join(&disk, &mut n, c, &YES).end, Some(End::Failed(Fail::NotSent(12), Revert::Reverted { country: "JP".into() })));
    assert_eq!(n.sets, ["US", "JP"]);
    assert_eq!(disk.mine(), Some(before));
}

#[test]
fn t7_nonce_refused_before_settings_set_restores_a_joining_entry_with_prev_country() {
    let (rec, before) = with_mine(Some("JP"), MemberState::Joining);
    let disk = Disk::new(&rec);
    let (c, mut n) = pair("JP");
    n.nonce_r.push_back(Some(12));
    let run = join(&disk, &mut n, c, &YES);
    assert_eq!(run.end, Some(End::Joining(Keep::NonceRefused(12))));
    assert!(n.sets.is_empty());
    assert_eq!(disk.mine(), Some(before), "the earlier joining entry and its prev_country are kept");
}

#[test]
fn t7_country_must_be_two_capital_letters() {
    for bad in ["us", "USA", "", "U1"] {
        let (run, n, disk) = join_with("JP", |n| n.get_r.push_back(R::Ok(country_of(bad))));
        assert!(matches!(run.end, Some(End::SettingsError(_))), "{bad:?}: {:?}", run.end);
        assert_eq!(n.got, ["settings/get"]);
        assert_eq!(disk.read().1, 1, "{bad:?}: nothing written");
    }
}

// ---- member mode (254-app-member-join §4 step 8, M9) ---------------------------------------------------------------

/// The member phone's mnet for the network of `record("US", ...)`, its secrets admin-signed for the joining node.
fn mnet(me: Option<Member>) -> MNet {
    let rec = applied_record("US");
    let node = joining_node();
    let dac = netrec::dac_hash(&node.dac_pub);
    let plain = cbor::encode(&m(vec![(1, V::Text(SAE.into())), (2, V::Bytes(vec![0x77; 32]))]));
    let e = cose::encrypt_to(&plain, cose::LABEL_SECRETS, &node.ecdh_pub, &dac, &NET_ID, 1).unwrap();
    let p = cose::net_secrets_payload(&NET_ID, 1, &dac, &e.object);
    let secrets = cose::sign1(cose::CT_SECRETS, &p, &sig::der_to_raw_low_s(&signed(ADMIN, &cose::sign1_tbs(cose::CT_SECRETS, cose::LABEL_SECRETS, &p))).unwrap());
    MNet { net_id: NET_ID, version: 1, netcfg: rec.base.netcfg, members: rec.base.members, secrets, net_root: [0x77; 32], me, invite_hash: [1; 32], versions: None, node_secrets: vec![] }
}
fn my_entry(state: MemberState) -> Member {
    Member { device_id: Some("aabbccddeeff00112233".into()), ..member(0x77, 0x42, "node-2233", state) }
}
fn member_join(x: &MNet, country: &str, set_up: impl FnOnce(&mut Node)) -> (Run, Node, Disk) {
    let disk = Disk::new_mnet(x);
    let (c, mut n) = pair(country);
    set_up(&mut n);
    let (plain, g) = disk.read();
    let inp = Input {
        record_plain: plain,
        record_gen: g,
        node: Some(joining_node()),
        node_name: String::new(),
        owner_pub: [0; 65],
        owner_enc_pub: [0; 65],
        admin_pub: [0; 65],
        member: true,
        removed_confirmed: false,
    };
    let (j, a) = Join2::start(c, inp);
    let run = drive(&mut n, &disk, j, a, &YES);
    (run, n, disk)
}

#[test]
fn m9_member_join_sends_the_approvals_secrets_and_writes_only_mnet() {
    let x = mnet(Some(my_entry(MemberState::Joining)));
    let (run, n, disk) = member_join(&x, "US", |_| {});
    assert_eq!(run.end, Some(End::Applied { country_unverified: false, save_pending: false }));
    assert_eq!(n.got, ["settings/get", "op/nonce", "network/join"]);
    assert_eq!(run.admin_signs, 0, "the secrets are the approval's: never signed here");
    assert!(!run.kinds.is_empty() && run.kinds.iter().all(|k| *k == "mnet"), "member mode never writes a net record: {:?}", run.kinds);
    assert_eq!(n.bodies[0], (x.netcfg.clone(), x.members.clone()));
    assert_eq!(n.sec_payloads[0], netrec::sign1_payload(&x.secrets).unwrap());
    assert_eq!(n.secrets, [(SAE.to_string(), vec![0x77; 32])]);
    let me = disk.mine().unwrap();
    assert_eq!((me.state, me.prev_country), (MemberState::Applied, None));
}

#[test]
fn m9_three_sends_the_same_request_once_more() {
    let x = mnet(Some(my_entry(MemberState::Joining)));
    let (run, n, _) = member_join(&x, "US", |n| n.join_r.push_back(R::Err(3, m(vec![]))));
    assert!(matches!(run.end, Some(End::Applied { .. })));
    assert_eq!(n.got, ["settings/get", "op/nonce", "network/join", "op/nonce", "network/join"]);
    assert_eq!(n.sec_payloads[0], n.sec_payloads[1], "the same secrets");
    assert_eq!(run.admin_signs, 0);
    let (run, n, disk) = member_join(&x, "US", |n| n.join_r.extend([R::Err(3, m(vec![])), R::Err(3, m(vec![]))]));
    assert_eq!(run.end, Some(End::Joining(Keep::TwiceRefused)));
    assert_eq!(n.got.iter().filter(|v| *v == "network/join").count(), 2);
    assert_eq!(disk.mine().unwrap().state, MemberState::Joining);
}

#[test]
fn m9_four_puts_the_country_back_then_drops_key_7() {
    let x = mnet(Some(my_entry(MemberState::Joining)));
    let (run, n, disk) = member_join(&x, "JP", |n| n.join_r.push_back(R::Err(4, m(vec![]))));
    assert_eq!(run.end, Some(End::Failed(Fail::Rejected, Revert::Reverted { country: "JP".into() })));
    assert_eq!(n.sets, ["US", "JP"]);
    assert!(disk.mine().is_none(), "key 7 dropped after the country went back");
    assert!(run.kinds.iter().all(|k| *k == "mnet"));
    // putting it back fails -> key 7 and prev_country stay
    let (run, _, disk) = member_join(&x, "JP", |n| {
        n.join_r.push_back(R::Err(4, m(vec![])));
        n.set_r.extend([R::Pass, R::Err(11, m(vec![]))]);
    });
    assert_eq!(run.end, Some(End::Failed(Fail::Rejected, Revert::NotReverted { now: "US".into(), was: "JP".into() })));
    let me = disk.mine().unwrap();
    assert_eq!((me.state, me.prev_country.as_deref()), (MemberState::Joining, Some("JP")));
}

#[test]
fn m9_member_preconditions() {
    // no key 7 -> refused, nothing sent
    let (run, n, _) = member_join(&mnet(None), "US", |_| {});
    assert_eq!(run.end, Some(End::Refused(Pre::NoEntry)));
    assert!(n.got.is_empty() && run.kinds.is_empty());
    // secrets for another node than this login's -> refused
    let mut x = mnet(Some(my_entry(MemberState::Joining)));
    x.secrets = applied_record("US").base.members; // a Sign1 whose key 3 is not this DAC hash
    let (run, n, _) = member_join(&x, "US", |_| {});
    assert_eq!(run.end, Some(End::Refused(Pre::NotThisNode)));
    assert!(n.got.is_empty());
    // a record that does not open as mnet
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair("US");
    let (plain, g) = disk.read();
    let inp = Input { record_plain: plain, record_gen: g, node: Some(joining_node()), node_name: String::new(), owner_pub: [0; 65], owner_enc_pub: [0; 65], admin_pub: [0; 65], member: true, removed_confirmed: false };
    let (j, a) = Join2::start(c, inp);
    assert_eq!(drive(&mut n, &disk, j, a, &YES).end, Some(End::Refused(Pre::Record)));
}

#[test]
fn m9_an_applied_entry_is_sent_too() {
    // key 7 applied, the node not in the network (re-flashed / restored): sent, 0 -> applied
    let x = mnet(Some(my_entry(MemberState::Applied)));
    let (run, n, disk) = member_join(&x, "US", |_| {});
    assert!(matches!(run.end, Some(End::Applied { .. })));
    assert!(n.got.contains(&"network/join".to_string()));
    assert_eq!(disk.mine().unwrap().state, MemberState::Applied);
}

#[test]
fn m9_member_reply_table_like_join2() {
    let x = mnet(Some(my_entry(MemberState::Joining)));
    // 7 -> info applied -> applied
    let (run, _, _) = member_join(&x, "US", |n| {
        n.join_r.push_back(R::Err(7, m(vec![])));
        n.info_r.push_back(R::Ok(info_applied(false)));
    });
    assert!(matches!(run.end, Some(End::Applied { .. })));
    // 7 -> info not applied -> keep, no revert
    let (run, n, disk) = member_join(&x, "JP", |n| {
        n.join_r.push_back(R::Err(7, m(vec![])));
        n.info_r.push_back(R::Ok(info_absent(false)));
    });
    assert_eq!(run.end, Some(End::Joining(Keep::Unclear7)));
    assert_eq!(n.sets, ["US"]);
    assert_eq!(disk.mine().unwrap().prev_country.as_deref(), Some("JP"));
    // 11 -> info not applied -> the country back, key 7 dropped
    let (run, _, disk) = member_join(&x, "JP", |n| {
        n.join_r.push_back(R::Err(11, m(vec![])));
        n.info_r.push_back(R::Ok(info_absent(false)));
    });
    assert_eq!(run.end, Some(End::Failed(Fail::NotApplied(11), Revert::Reverted { country: "JP".into() })));
    assert!(disk.mine().is_none());
    // 5 -> info ours -> applied
    let (run, _, _) = member_join(&x, "US", |n| {
        n.join_r.push_back(R::Err(5, m(vec![])));
        n.info_r.push_back(R::Ok(info_applied(false)));
    });
    assert!(matches!(run.end, Some(End::Applied { .. })));
}

// ---- M7 / M10 on the admin's join2 path ----------------------------------------------------------------------

#[test]
fn m7_key_12_survives_an_admin_join() {
    let mut rec = applied_record("US");
    let inv = Some(vec![InviteRec { hash: [5; 32], kind: 1, used: true }]);
    rec.invites = inv.clone();
    let disk = Disk::new(&rec);
    let (c, mut n) = pair("US");
    assert!(matches!(join(&disk, &mut n, c, &YES).end, Some(End::Applied { .. })));
    assert_eq!(disk.rec().invites, inv);
}

#[test]
fn m10_approved_entries_count_toward_16() {
    let mut l = others(15);
    l.push(member(0x60, 0x43, "approved", MemberState::Approved));
    let (run, got, _) = refused(&record("US", &[pub_of(&key(ADMIN))], "applied", Some(l)), Some(joining_node()));
    assert_eq!(run.end, Some(End::Refused(Pre::Full)));
    assert!(got.is_empty());
}

// ---- member-join review round 3 -------------------------------------------------------------------------------

#[test]
fn r3_an_owner_signature_failure_is_unclear_and_keeps_prev_country() {
    // the settings.set owner-op cannot be signed (country not changed yet, the entry already joining + JP)
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair("JP");
    let run = join(&disk, &mut n, c, &Opts { owner_fail_at: Some(0), ..YES });
    assert_eq!(run.end, Some(End::Joining(Keep::Unclear)));
    assert!(n.sets.is_empty() && !n.got.contains(&"settings/set".to_string()));
    let me = disk.mine().unwrap();
    assert_eq!((me.state, me.prev_country.as_deref()), (MemberState::Joining, Some("JP")));
    // the network/join owner-op cannot be signed
    let disk = Disk::new(&applied_record("US"));
    let (c, mut n) = pair("US");
    let run = join(&disk, &mut n, c, &Opts { owner_fail_at: Some(0), ..YES });
    assert_eq!(run.end, Some(End::Joining(Keep::Unclear)));
    assert!(!n.got.contains(&"network/join".to_string()));
}

// ---- remove-member (docs/design/254-app-remove-member.md v6.4) ------------------------------------------------------

fn signed_by_admin(ct: &str, p: &[u8]) -> Vec<u8> {
    cose::sign1(ct, p, &sig::der_to_raw_low_s(&signed(ADMIN, &cose::sign1_tbs(ct, cose::label_of(ct).unwrap(), p))).unwrap())
}

/// T27 rule 2: a node in some version's removed list joins only with the admin's yes (a parameter of the start),
/// checked before the first SignAdmin and any write
#[test]
fn rm_t27_rule2_a_node_removed_before_needs_the_admins_yes() {
    let mut rec = applied_record("US");
    let first = member(0x55, 0x43, "node-0001", MemberState::Applied);
    let mut mp = cbor::decode(&cose::member_list_payload(
        &NET_ID,
        1,
        None,
        &[cose::Member { dac_pub_hash: &first.dac_pub_hash, ecdh_pub: &first.ecdh_pub, name: &first.name, owner_pub: &first.owner_pub, owner_enc_pub: &first.owner_enc_pub }],
    ))
    .unwrap();
    if let V::Map(e) = &mut mp {
        for (k, v) in e.iter_mut() {
            if *k == V::Uint(5) {
                *v = V::Array(vec![V::Bytes(netrec::dac_hash(&joining_node().dac_pub).to_vec())]);
            }
        }
    }
    rec.base.members = signed_by_admin(cose::CT_MEMBERS, &cbor::encode(&mp));
    let disk = Disk::new(&rec);
    let (conn, node) = pair("US");
    let (_, a) = Join2::start(conn, input(&disk, Some(joining_node())));
    assert_eq!(a, Action::Done(End::Refused(Pre::RemovedBefore)));
    assert!(node.got.is_empty());
    assert_eq!(disk.read().1, 1, "nothing written");
    // yes -> today's join2
    let (conn, mut node) = pair("US");
    let mut inp = input(&disk, Some(joining_node()));
    inp.removed_confirmed = true;
    let (j, a) = Join2::start(conn, inp);
    assert!(matches!(a, Action::SignAdmin { .. }));
    let run = drive(&mut node, &disk, j, a, &YES);
    assert!(matches!(run.end, Some(End::Applied { .. })), "{:?}", run.end);
    // negative control: a node that was never removed needs no yes (t1 joins with removed_confirmed false)
}

/// T23: the node answered 5 (already a member) and info says an older version -> node_behind (the bridge sends the
/// new secrets right away); a join the node applied (0) is never behind
#[test]
fn rm_t23_a_member_node_behind_after_reply_5() {
    let mut rec = applied_record("US");
    let mesh = format!("bm-{}", hex::encode(&NET_ID[..6]));
    let prev = cose::object_hash(&rec.base.netcfg).unwrap();
    rec.base.netcfg = signed_by_admin(cose::CT_NETCFG, &cose::net_config_payload(&NET_ID, 2, Some(&prev), "home", "US", &mesh, 40, 4, &[pub_of(&key(ADMIN))]));
    let disk = Disk::new(&rec);
    let (conn, mut node) = pair("US");
    node.join_r.push_back(R::Err(5, m(vec![])));
    node.in_net = true;
    let (j, a) = Join2::start(conn, input(&disk, Some(joining_node())));
    let (run, j) = drive_keep(&mut node, &disk, j, a, &YES);
    assert!(matches!(run.end, Some(End::Applied { .. })), "{:?}", run.end);
    assert!(j.node_behind(), "info key 9 = 1 < the record's 2");
    let disk = Disk::new(&rec);
    let (conn, mut node) = pair("US");
    let (j, a) = Join2::start(conn, input(&disk, Some(joining_node())));
    let (run, j) = drive_keep(&mut node, &disk, j, a, &YES);
    assert!(matches!(run.end, Some(End::Applied { .. })));
    assert!(!j.node_behind(), "reply 0: the node took the record's version");
}
