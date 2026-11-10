//! Remote invites (254-app-member-join v6.1 §7: M1-M8, M10, M12, M13; M9 is in join2flow.rs with the fake node).
//! The admin side (invite, check, approve) and the joiner side (open, request, import) run against each other through
//! the real record store with a fake seal that binds the AAD, keys from the 219 vectors (gen.py scalars), and a dev
//! node_cert the offline check accepts (the vectors' own node_cert has a test-root DAC: Untrusted).
//! A dev-trust build only (the remote-invite path is dev / bench only, §5-5; the field build's refusal of the dev
//! node_cert is tests/offline.rs).
#![cfg(feature = "dev-trust")]

use batman_proto::approve::{self, ApproveFlow, Prepared};
use batman_proto::cbor::{self, Value as V};
use batman_proto::cose;
use batman_proto::invite::{self, Action, End, Error, InviteFlow, JoinReqFlow, JoinReqInput};
use batman_proto::joinflow::NetRecord;
use batman_proto::mrec::{self, MNet, Pend};
use batman_proto::netrec::{self, InviteRec, Member, MemberState, NetRec};
use batman_proto::nodecert::{self, Verified};
use batman_proto::{sig, store};
use p256::ecdsa::signature::Signer;
use serde_json::Value as J;
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

// gen.py: d = (int(SHA-256('batman-test-vector/'+name)) mod (n-1)) + 1
const ADMIN_PRIV: &str = "a9f29475b615d8d001781eb6b94515f8503026e32e8a89c8dbde1bf9f655a4f5";
const OWNER_SIGN_PRIV: &str = "d4a5cfbe7887f7cdf609cd12b6a3f53bf3fb7d24ae09ee28eeebec7003833f57";
const OWNER_ENC_PRIV: &str = "31af876990ae00a6dfcff571dd42e5f9d29887e0b61bd5994fb4a7f977152b1f";
const NODE_ECDH_PRIV: &str = "5fc9a2c8dc0c10edeec4d50654765f2d4aee146880e072d036f584e55bbf3764";
const EPH_MEMBER_PRIV: &str = "7613b01040f9bc83987ecce315bc080dda564781404eb39058652bfd0ef92c1a";
const IV_MSECRETS: &str = "475ade4db7302bbee204a896";
const INVITE_ID: &str = "ff38234b74011dcae0fe5cfb4b6cf8bc";
// the dev node of tests/loginflow.rs (identity_file's self-signed dev: DAC)
const DEV_NODE_PRIV: &str = "1018ee07c7a494aa6b01e3afc3da234d5f664656dddcbd5f1022c0686f571769";

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
fn sk(hexs: &str) -> p256::ecdsa::SigningKey {
    p256::ecdsa::SigningKey::from_slice(&hex::decode(hexs).unwrap()).unwrap()
}
fn pub65(k: &p256::ecdsa::SigningKey) -> [u8; 65] {
    k.verifying_key().to_sec1_point(false).as_bytes().try_into().unwrap()
}
fn der(k: &p256::ecdsa::SigningKey, msg: &[u8]) -> Vec<u8> {
    let s: p256::ecdsa::Signature = k.sign(msg);
    s.to_der().as_bytes().to_vec()
}
fn raw(k: &p256::ecdsa::SigningKey, msg: &[u8]) -> [u8; 64] {
    sig::der_to_raw_low_s(&der(k, msg)).unwrap()
}
fn admin() -> p256::ecdsa::SigningKey {
    sk(ADMIN_PRIV)
}
fn owner() -> p256::ecdsa::SigningKey {
    sk(OWNER_SIGN_PRIV)
}
fn owner_enc_pub() -> [u8; 65] {
    pub65(&sk(OWNER_ENC_PRIV))
}
/// the receiver side of ECDH-ES (what Kotlin's Keys.ecdh(OWNER_ENC) returns)
fn ecdh_z(priv_hex: &str, peer: &[u8; 65]) -> [u8; 32] {
    let s = p256::SecretKey::from_slice(&hex::decode(priv_hex).unwrap()).unwrap();
    let z = p256::ecdh::diffie_hellman(s.to_nonzero_scalar(), p256::PublicKey::from_sec1_bytes(peer).unwrap().as_affine());
    z.raw_secret_bytes().as_slice().try_into().unwrap()
}
fn sign1(k: &p256::ecdsa::SigningKey, ctype: &str, payload: &[u8]) -> Vec<u8> {
    let label = cose::label_of(ctype).unwrap();
    cose::sign1(ctype, payload, &raw(k, &cose::sign1_tbs(ctype, label, payload)))
}

/// the dev node: identity_file's dev: DAC, the vectors' node ECDH key
fn dev_node_cert(v: &J) -> Vec<u8> {
    let k = sk(DEV_NODE_PRIV);
    let s_node = h(&v["keys"]["s_node_pub"]);
    let boot_id = vec![7u8; 16];
    let ecdh_pub = h(&v["keys"]["node_ecdh_pub"]);
    let mut a = nodecert::LABEL_STATIC.to_vec();
    a.extend(&s_node);
    a.extend(&boot_id);
    let mut b = nodecert::LABEL_ECDH.to_vec();
    b.extend(&ecdh_pub);
    cbor::encode(&m(vec![
        (1, V::Array(vec![V::Bytes(h(&v["identity_file"]["dev_cert_der"]))])),
        (2, V::Bytes(s_node)),
        (3, V::Bytes(boot_id)),
        (4, V::Bytes(ecdh_pub)),
        (5, V::Bytes(raw(&k, &a).to_vec())),
        (6, V::Bytes(raw(&k, &b).to_vec())),
        (7, V::Bytes(h(&v["identity_file"]["sn"]))),
    ]))
}
fn dev_verified(v: &J) -> Verified {
    nodecert::verify_offline(&dev_node_cert(v)).expect("the dev node_cert passes offline in a dev-trust build")
}
fn dev_dac_hash(v: &J) -> [u8; 32] {
    netrec::dac_hash(&dev_verified(v).dac_pub)
}

/// The admin's applied record for the vectors' network (netcfg / members v1 from the vectors, admin = vectors admin).
fn admin_record(v: &J) -> NetRec {
    let c = &v["cose"];
    let base = NetRecord {
        net_id: h(&v["keys"]["net_id"]).try_into().unwrap(),
        mesh_id: "bm-a5faaf844ee7".into(),
        channel: 40,
        bw: 4,
        sae: "correct-horse-battery".into(),
        net_root: h(&v["keys"]["net_root"]).try_into().unwrap(),
        netcfg: h(&c["net_config"]["sign1"]),
        members: h(&c["member_list"]["sign1"]),
        secrets: h(&c["net_secrets"]["sign1"]),
    };
    NetRec { base, state: "applied".into(), list: None, invites: None }
}

/// The real store with a fake seal: sealed = SHA-256(aad) ‖ plain.
struct Disk(store::Store);
static N: AtomicU32 = AtomicU32::new(0);
impl Disk {
    fn new() -> Disk {
        let d = std::env::temp_dir().join(format!("bp-member-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
        let _ = std::fs::remove_dir_all(&d);
        Disk(store::Store::new(d))
    }
    fn put(&self, rel: &str, plain: &[u8]) -> u64 {
        let g = self.0.read(rel).unwrap().map_or(0, |s| s.generation);
        self.0.write_cas(rel, g, &seal(rel, g + 1, plain)).unwrap()
    }
    fn get(&self, rel: &str) -> Option<(u64, Vec<u8>)> {
        let r = self.0.read(rel).unwrap()?;
        Some((r.generation, open(rel, r.generation, &r.sealed).expect("opens with aad(rel, generation)")))
    }
    fn cas(&self, rel: &str, expected: u64, plain: &[u8]) -> Result<u64, store::Error> {
        self.0.write_cas(rel, expected, &seal(rel, expected + 1, plain))
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

#[derive(Default, Debug)]
struct Run {
    end: Option<End>,
    signs: Vec<&'static str>,
    writes: Vec<(String, u64)>,
}

trait Flow {
    fn signed(&mut self, der: &[u8]) -> Option<Action>;
    fn persisted(&mut self) -> Option<Action>;
    fn persist_failed(&mut self, e: Option<String>) -> Option<Action>;
}
impl Flow for InviteFlow {
    fn signed(&mut self, d: &[u8]) -> Option<Action> {
        InviteFlow::signed(self, d)
    }
    fn persisted(&mut self) -> Option<Action> {
        InviteFlow::persisted(self)
    }
    fn persist_failed(&mut self, e: Option<String>) -> Option<Action> {
        InviteFlow::persist_failed(self, e)
    }
}
impl Flow for ApproveFlow {
    fn signed(&mut self, d: &[u8]) -> Option<Action> {
        ApproveFlow::signed(self, d)
    }
    fn persisted(&mut self) -> Option<Action> {
        ApproveFlow::persisted(self)
    }
    fn persist_failed(&mut self, e: Option<String>) -> Option<Action> {
        ApproveFlow::persist_failed(self, e)
    }
}
impl Flow for JoinReqFlow {
    fn signed(&mut self, d: &[u8]) -> Option<Action> {
        JoinReqFlow::signed(self, d)
    }
    fn persisted(&mut self) -> Option<Action> {
        JoinReqFlow::persisted(self)
    }
    fn persist_failed(&mut self, e: Option<String>) -> Option<Action> {
        JoinReqFlow::persist_failed(self, e)
    }
}

/// drives a flow: admin key for SignAdmin, owner key for SignOwner, write_cas for Persist (`bump`: a write elsewhere
/// first)
fn drive<F: Flow>(disk: &Disk, mut f: F, mut a: Action, bump: bool) -> Run {
    let mut run = Run::default();
    loop {
        a = match a {
            Action::SignAdmin { tbs } => {
                run.signs.push("admin");
                f.signed(&der(&admin(), &tbs)).unwrap()
            }
            Action::SignOwner { input } => {
                run.signs.push("owner");
                f.signed(&der(&owner(), &input)).unwrap()
            }
            Action::Persist { rel, plain, expected_gen } => {
                if bump {
                    let (g, p) = disk.get(&rel).unwrap();
                    disk.cas(&rel, g, &p).unwrap();
                }
                run.writes.push((rel.clone(), expected_gen));
                match disk.cas(&rel, expected_gen, &plain) {
                    Ok(_) => f.persisted().unwrap(),
                    Err(store::Error::Stale { .. }) => f.persist_failed(None).unwrap(),
                    Err(e) => panic!("{e:?}"),
                }
            }
            Action::Done(e) => {
                run.end = Some(e);
                return run;
            }
        };
    }
}

fn out(r: &Run) -> (String, String, String, bool) {
    match &r.end {
        Some(End::Out { hex, sas, name, renewed }) => (hex.clone(), sas.clone(), name.clone(), *renewed),
        e => panic!("no output: {e:?}"),
    }
}
fn refused(r: &Run) -> Error {
    match &r.end {
        Some(End::Refused(e)) => e.clone(),
        e => panic!("not refused: {e:?}"),
    }
}

const REL: &str = "net/a5faaf844ee7c02b2909617cadbbd809";
const PEND: &str = "mpend/a5faaf844ee7c02b2909617cadbbd809";
const MNET: &str = "mnet/a5faaf844ee7c02b2909617cadbbd809";

/// the admin's disk with the record; returns the invite hex
fn invite(v: &J, disk: &Disk) -> String {
    if disk.get(REL).is_none() {
        disk.put(REL, &netrec::encode(&admin_record(v)));
    }
    let (g, p) = disk.get(REL).unwrap();
    let (f, a) = InviteFlow::start(&p, g, &pub65(&admin()));
    out(&drive(disk, f, a, false)).0
}

fn jr_input(v: &J, invite_hex: &str, name: &str, pend: Option<(u64, Vec<u8>)>) -> JoinReqInput {
    let (pend_gen, pend_plain) = pend.map_or((0, None), |(g, p)| (g, Some(p)));
    JoinReqInput {
        invite_hex: invite_hex.into(),
        name: name.into(),
        node: Some(dev_verified(v)),
        node_cert_raw: Some(dev_node_cert(v)),
        owner_pub: pub65(&owner()),
        owner_enc_pub: owner_enc_pub(),
        pend_gen,
        pend_plain,
    }
}

/// the joiner's request (its own disk); returns (hex, sas, run)
fn request(v: &J, mdisk: &Disk, invite_hex: &str, name: &str) -> (String, String, Run) {
    let (f, a) = JoinReqFlow::start(jr_input(v, invite_hex, name, mdisk.get(PEND)));
    let r = drive(mdisk, f, a, false);
    let (hex, sas, _, _) = out(&r);
    (hex, sas, r)
}

fn approve(disk: &Disk, jr_hex: &str) -> Run {
    let (g, p) = disk.get(REL).unwrap();
    let c = approve::check_joinreq(&netrec::decode(&p).unwrap(), &invite::qr_object(jr_hex, invite::QR_JOINREQ).unwrap()).unwrap();
    let (f, a) = ApproveFlow::start(&p, g, jr_hex, &c.jr.hash, &pub65(&admin()));
    drive(disk, f, a, false)
}

/// all the way to a pasted approval on the joiner's side
fn to_approval(v: &J) -> (Disk, Disk, String, String) {
    let (ad, md) = (Disk::new(), Disk::new());
    let inv = invite(v, &ad);
    let (jr, sas, _) = request(v, &md, &inv, "客廳");
    let ap = out(&approve(&ad, &jr)).0;
    (ad, md, ap, sas)
}

fn prepare(md: &Disk, ap: &str) -> Result<Prepared, Error> {
    let pend = md.get(PEND);
    let mnet = md.get(MNET).map(|x| x.1);
    approve::prepare_import(ap, pend.as_ref().map(|(g, p)| (*g, &p[..])), mnet.as_deref())
}

fn import(md: &Disk, ap: &str, pend_gen: u64, sas: &str) -> Result<(Vec<u8>, [u8; 16], u64), Error> {
    let (g, p) = md.get(PEND).unwrap();
    let mnet = md.get(MNET);
    let eph = match prepare(md, ap)? {
        Prepared::Ready { eph_pub, .. } => eph_pub,
        x => panic!("{x:?}"),
    };
    let z = ecdh_z(OWNER_ENC_PRIV, &eph);
    approve::import(ap, (g, &p), pend_gen, mnet.as_ref().map(|(g, p)| (&p[..], *g)), &z, sas)
}

fn import_all(md: &Disk, ap: &str) -> MNet {
    let (sas, gen) = match prepare(md, ap).unwrap() {
        Prepared::Ready { sas, pend_gen, .. } => (sas, pend_gen),
        x => panic!("{x:?}"),
    };
    let (plain, _, mg) = import(md, ap, gen, &sas).unwrap();
    md.cas(MNET, mg, &plain).unwrap();
    md.0.remove(PEND).unwrap();
    MNet::decode(&plain).unwrap()
}

// ---- M1 vectors -------------------------------------------------------------------------------------------------

#[test]
fn m1_objects_rebuilt_from_the_vector_inputs() {
    let v = vectors();
    let c = &v["cose"];
    let net_id: [u8; 16] = h(&v["keys"]["net_id"]).try_into().unwrap();
    let netcfg = h(&c["net_config"]["sign1"]);
    // invite (remote)
    let ip = invite::invite_payload(&net_id, &h(&J::from(INVITE_ID)).try_into().unwrap(), cbor::decode(&netcfg).unwrap(), &pub65(&admin()));
    let inv = sign1(&admin(), cose::CT_INVITE, &ip);
    assert_eq!(hex::encode(&inv), c["invite_remote"].as_str().unwrap());
    assert_eq!(invite::qr_hex(invite::QR_INVITE, &inv), c["qr_invite_object"].as_str().unwrap());
    // join request
    let sig_enc: [u8; 64] = h(&v["owner_enc"]["sig_enc"]).try_into().unwrap();
    let jp = invite::joinreq_payload(&cose::object_hash(&inv).unwrap(), cbor::decode(&h(&v["node_cert"]["cbor"])).unwrap(), &pub65(&owner()), &owner_enc_pub(), &sig_enc, "客廳");
    let jr = sign1(&owner(), cose::CT_JOINREQ, &jp);
    assert_eq!(hex::encode(&jr), c["join_request"].as_str().unwrap());
    // member secrets (fixed ephemeral key and IV)
    let target: [u8; 32] = Sha256::digest(owner_enc_pub()).into();
    let plain = h(&c["member_secrets"]["plaintext"]);
    let e = cose::encrypt_with_fixed_for_vectors(&plain, cose::LABEL_MSECRETS, &owner_enc_pub(), &target, &net_id, 1, &hex::decode(EPH_MEMBER_PRIV).unwrap().try_into().unwrap(), &hex::decode(IV_MSECRETS).unwrap().try_into().unwrap()).unwrap();
    let ms = sign1(&admin(), cose::CT_MSECRETS, &cose::net_secrets_payload(&net_id, 1, &target, &e.object));
    assert_eq!(hex::encode(&ms), c["member_secrets"]["sign1"].as_str().unwrap());
    // ... and it decrypts back with the vector's z (the receiver side)
    let z: [u8; 32] = h(&c["member_secrets"]["ecdh_z"]).try_into().unwrap();
    let s = cose::verify_sign1(&ms, cose::CT_MSECRETS, cose::LABEL_MSECRETS, &[pub65(&admin())]).unwrap();
    assert_eq!(cose::decrypt(s.payload.get(4).unwrap(), cose::LABEL_MSECRETS, &target, &net_id, 1, &z).unwrap(), plain);
    // approval bundle and its qr-object
    let item = |b: &[u8]| cbor::decode(b).unwrap();
    let bundle = cbor::encode(&m(vec![(2, item(&h(&c["member_list"]["sign1"]))), (3, item(&h(&c["net_secrets"]["sign1"]))), (4, item(&ms))]));
    assert_eq!(hex::encode(&bundle), c["approval_bundle"].as_str().unwrap());
    assert_eq!(invite::qr_hex(invite::QR_APPROVAL, &bundle), c["qr_approval_object"].as_str().unwrap());
    // SAS
    assert_eq!(invite::sas(&cose::object_hash(&inv).unwrap(), &cose::object_hash(&jr).unwrap()), v["sas"]["sas"].as_str().unwrap());
    // and the opened vector invite says what it was built from
    let o = invite::open_invite(&inv).unwrap();
    assert_eq!((o.net_id, o.invite_id.to_vec(), o.cfg.name.as_str()), (net_id, hex::decode(INVITE_ID).unwrap(), "家裡網路"));
}

#[test]
fn m1_vector_join_request_has_a_test_root_dac_untrusted_offline() {
    let v = vectors();
    let r = approve::open_joinreq(&h(&v["cose"]["join_request"]));
    assert_eq!(r, Err(Error::NodeCert(nodecert::Error::Untrusted)));
}

// ---- M2 verify_sign1 / object_hash ------------------------------------------------------------------------------

fn parts(obj: &[u8]) -> Vec<V> {
    let V::Tag(18, a) = cbor::decode(obj).unwrap() else { panic!() };
    let V::Array(a) = *a else { panic!() };
    a
}
fn tagged(a: Vec<V>) -> Vec<u8> {
    cbor::encode(&V::Tag(18, Box::new(V::Array(a))))
}
fn high_s(sig: &[u8]) -> Vec<u8> {
    let n = hex::decode("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551").unwrap();
    let lo = &sig[32..];
    let mut hi = [0u8; 32];
    let mut borrow = 0i16;
    for i in (0..32).rev() {
        let d = n[i] as i16 - lo[i] as i16 - borrow;
        hi[i] = d.rem_euclid(256) as u8;
        borrow = if d < 0 { 1 } else { 0 };
    }
    let mut o = sig[..32].to_vec();
    o.extend(hi);
    o
}

#[test]
fn m2_verify_sign1_is_strict() {
    let v = vectors();
    let inv = h(&v["cose"]["invite_remote"]);
    let keys = [pub65(&admin())];
    let ok = |o: &[u8]| cose::verify_sign1(o, cose::CT_INVITE, cose::LABEL_INVITE, &keys);
    assert!(ok(&inv).is_ok());
    let a = parts(&inv);
    // high-s
    let mut b = a.clone();
    b[3] = V::Bytes(high_s(a[3].as_bytes().unwrap()));
    assert_eq!(ok(&tagged(b.clone())), Err(cose::Error::Malformed("high-s signature")));
    let hs = tagged(b);
    // unprotected not empty
    let mut b = a.clone();
    b[1] = m(vec![(4, V::Bytes(vec![1]))]);
    assert_eq!(ok(&tagged(b.clone())), Err(cose::Error::Malformed("unprotected header is not empty")));
    let unprot = tagged(b);
    // not tagged
    assert!(ok(&cbor::encode(&V::Array(a.clone()))).is_err());
    // wrong content type / wrong label
    assert!(cose::verify_sign1(&inv, cose::CT_JOINREQ, cose::LABEL_INVITE, &keys).is_err());
    assert_eq!(cose::verify_sign1(&inv, cose::CT_INVITE, cose::LABEL_JOINREQ, &keys), Err(cose::Error::Signature));
    // OBJECT_HASH ignores the signature (n - s) and the unprotected header
    let base = cose::object_hash(&inv).unwrap();
    assert_eq!(cose::object_hash(&hs).unwrap(), base);
    assert_eq!(cose::object_hash(&unprot).unwrap(), base);
    // ... and equals the Sig_structure hash verify_sign1 reports
    assert_eq!(ok(&inv).unwrap().hash, base);
}

#[test]
fn m2_unknown_keys_are_refused_nested_too() {
    let v = vectors();
    let net_id: [u8; 16] = h(&v["keys"]["net_id"]).try_into().unwrap();
    let id: [u8; 16] = hex::decode(INVITE_ID).unwrap().try_into().unwrap();
    let netcfg = cbor::decode(&h(&v["cose"]["net_config"]["sign1"])).unwrap();
    // an unknown key in the invite payload
    let mut p = cbor::decode(&invite::invite_payload(&net_id, &id, netcfg.clone(), &pub65(&admin()))).unwrap();
    if let V::Map(e) = &mut p {
        e.push((V::Uint(9), V::Uint(1)));
    }
    let inv = sign1(&admin(), cose::CT_INVITE, &cbor::encode(&p));
    assert_eq!(invite::open_invite(&inv), Err(Error::Invalid("invite keys")));
    // an unknown key inside the embedded netcfg (re-signed: only the key set is wrong)
    let mut cp = cbor::decode(&h(&v["cose"]["net_config"]["payload"])).unwrap();
    if let V::Map(e) = &mut cp {
        e.push((V::Uint(9), V::Uint(1)));
    }
    let bad_cfg = cbor::decode(&sign1(&admin(), cose::CT_NETCFG, &cbor::encode(&cp))).unwrap();
    let inv = sign1(&admin(), cose::CT_INVITE, &invite::invite_payload(&net_id, &id, bad_cfg, &pub65(&admin())));
    assert_eq!(invite::open_invite(&inv), Err(Error::Invalid("netcfg keys")));
    // an unknown key in a join request's node_cert
    let mut nc = cbor::decode(&dev_node_cert(&v)).unwrap();
    if let V::Map(e) = &mut nc {
        e.push((V::Uint(8), V::Uint(1)));
    }
    assert!(matches!(nodecert::verify_offline(&cbor::encode(&nc)), Err(nodecert::Error::Malformed(_))));
    let sig_enc = raw(&owner(), &sig::owner_enc_input(&owner_enc_pub()));
    let jr = sign1(&owner(), cose::CT_JOINREQ, &invite::joinreq_payload(&[1; 32], nc, &pub65(&owner()), &owner_enc_pub(), &sig_enc, "x"));
    assert!(matches!(approve::open_joinreq(&jr), Err(Error::NodeCert(nodecert::Error::Malformed(_)))));
}

// ---- M3 open_invite ---------------------------------------------------------------------------------------------

#[test]
fn m3_open_invite_refusals() {
    let v = vectors();
    let net_id: [u8; 16] = h(&v["keys"]["net_id"]).try_into().unwrap();
    let id: [u8; 16] = hex::decode(INVITE_ID).unwrap().try_into().unwrap();
    let netcfg = cbor::decode(&h(&v["cose"]["net_config"]["sign1"])).unwrap();
    // admin_pub not in the netcfg admins (a stranger signs a real netcfg into an invite)
    let stranger = sk(OWNER_ENC_PRIV);
    let inv = sign1(&stranger, cose::CT_INVITE, &invite::invite_payload(&net_id, &id, netcfg.clone(), &pub65(&stranger)));
    assert_eq!(invite::open_invite(&inv), Err(Error::Invalid("admin_pub is not one of the network's admins")));
    // a broken signature
    let mut a = parts(&h(&v["cose"]["invite_remote"]));
    let mut s = a[3].as_bytes().unwrap().to_vec();
    s[5] ^= 1;
    a[3] = V::Bytes(s);
    assert_eq!(invite::open_invite(&tagged(a)), Err(Error::Invalid("signature")));
    // kind 0 (in person: carries the SAE, never pasted)
    assert!(invite::open_invite(&h(&v["cose"]["invite_in_person"])).is_err());
    // invite key 1 != the embedded netcfg's key 1
    let inv = sign1(&admin(), cose::CT_INVITE, &invite::invite_payload(&[9; 16], &id, netcfg, &pub65(&admin())));
    assert_eq!(invite::open_invite(&inv), Err(Error::Invalid("invite net_id is not the netcfg's")));
}

// ---- M4 request_joinreq / verify_offline -------------------------------------------------------------------------

#[test]
fn m4_request_reruns_open_invite_first() {
    let v = vectors();
    let md = Disk::new();
    let stranger = sk(OWNER_ENC_PRIV);
    let net_id: [u8; 16] = h(&v["keys"]["net_id"]).try_into().unwrap();
    let bad = sign1(&stranger, cose::CT_INVITE, &invite::invite_payload(&net_id, &[1; 16], cbor::decode(&h(&v["cose"]["net_config"]["sign1"])).unwrap(), &pub65(&stranger)));
    let (f, a) = JoinReqFlow::start(jr_input(&v, &invite::qr_hex(1, &bad), "客廳", None));
    let r = drive(&md, f, a, false);
    assert!(matches!(refused(&r), Error::Invalid(_)));
    assert!(r.signs.is_empty() && r.writes.is_empty() && md.get(PEND).is_none(), "no SignOwner, no mpend");
}

#[test]
fn m4_no_verified_node_cert_is_refused() {
    let v = vectors();
    let (ad, md) = (Disk::new(), Disk::new());
    let inv = invite(&v, &ad);
    let mut i = jr_input(&v, &inv, "客廳", None);
    i.node_cert_raw = None;
    let (f, a) = JoinReqFlow::start(i);
    let r = drive(&md, f, a, false);
    assert_eq!(refused(&r), Error::NoNodeCert);
    assert!(r.signs.is_empty() && md.get(PEND).is_none());
}

#[test]
fn m4_same_node_same_invite_shows_the_stored_request() {
    let v = vectors();
    let (ad, md) = (Disk::new(), Disk::new());
    let inv = invite(&v, &ad);
    let (hex1, sas1, r1) = request(&v, &md, &inv, "客廳");
    assert_eq!(r1.signs, ["owner", "owner"], "sig_enc, then the request");
    assert!(matches!(r1.end, Some(End::Out { renewed: true, .. })));
    // again with another name: the same hex / SAS / stored name, nothing signed or written
    let (f, a) = JoinReqFlow::start(jr_input(&v, &inv, "書房", md.get(PEND)));
    let r2 = drive(&md, f, a, false);
    let (hex2, sas2, name2, renewed) = out(&r2);
    assert_eq!((hex2, sas2, name2.as_str(), renewed), (hex1, sas1, "客廳", false));
    assert!(r2.signs.is_empty() && r2.writes.is_empty());
}

#[test]
fn m4_another_invite_or_unreadable_pend_overwrites_at_the_read_generation() {
    let v = vectors();
    let (ad, md) = (Disk::new(), Disk::new());
    let inv1 = invite(&v, &ad);
    let (_, sas1, _) = request(&v, &md, &inv1, "客廳");
    let inv2 = invite(&v, &ad);
    let (_, sas2, r) = request(&v, &md, &inv2, "客廳");
    assert_eq!(r.signs, ["owner", "owner"]);
    assert_eq!(r.writes, [(PEND.to_string(), 1)], "overwritten from the generation read");
    assert_ne!(sas1, sas2);
    assert!(matches!(r.end, Some(End::Out { renewed: true, .. })));
    // the new request carries a sig_enc signed now (it verifies)
    assert!(approve::open_joinreq(&invite::qr_object(&out(&r).0, invite::QR_JOINREQ).unwrap()).is_ok());
    // pend that does not open (None) at generation 2: signed afresh and written from 2
    let (f, a) = JoinReqFlow::start(JoinReqInput { pend_plain: None, pend_gen: 2, ..jr_input(&v, &inv2, "客廳", None) });
    let r = drive(&md, f, a, false);
    assert_eq!(r.signs, ["owner", "owner"]);
    assert_eq!(r.writes, [(PEND.to_string(), 2)]);
    assert_eq!(md.get(PEND).unwrap().0, 3);
}

#[test]
fn m4_verify_offline_trust_gate() {
    let v = vectors();
    // the vectors' node_cert: a test-root DAC, not dev: -> Untrusted (no production root yet)
    assert_eq!(nodecert::verify_offline(&h(&v["node_cert"]["cbor"])), Err(nodecert::Error::Untrusted));
    // the dev node_cert: accepted only by a dev-trust build
    let r = nodecert::verify_offline(&dev_node_cert(&v));
    if nodecert::DEV_TRUST {
        assert!(r.is_ok());
    } else {
        assert_eq!(r, Err(nodecert::Error::Untrusted));
    }
}

// ---- M5 check_joinreq -------------------------------------------------------------------------------------------

#[test]
fn m5_check_joinreq_refusals() {
    let v = vectors();
    let (ad, md) = (Disk::new(), Disk::new());
    let inv = invite(&v, &ad);
    let (jr_hex, sas, _) = request(&v, &md, &inv, "客廳");
    let jr = invite::qr_object(&jr_hex, invite::QR_JOINREQ).unwrap();
    let rec = netrec::decode(&ad.get(REL).unwrap().1).unwrap();
    let c = approve::check_joinreq(&rec, &jr).unwrap();
    assert_eq!((c.sas.as_str(), c.jr.name.as_str(), c.replaces_approved), (sas.as_str(), "客廳", false));
    // hash not in key 12 (another network's record / no invites)
    let mut other = rec.clone();
    other.invites = None;
    assert_eq!(approve::check_joinreq(&other, &jr), Err(Error::UnknownInvite));
    // the invite already used
    let mut used = rec.clone();
    used.invites.as_mut().unwrap()[0].used = true;
    assert_eq!(approve::check_joinreq(&used, &jr), Err(Error::InviteUsed));
    // signed by another key than the payload's owner_pub
    let p = netrec::sign1_payload(&jr).unwrap();
    let forged = sign1(&sk(OWNER_ENC_PRIV), cose::CT_JOINREQ, &cbor::encode(&p));
    assert_eq!(approve::check_joinreq(&rec, &forged), Err(Error::Invalid("signature")));
    // sig_enc that does not verify
    let mut p2 = p.clone();
    if let V::Map(e) = &mut p2 {
        for (k, x) in e.iter_mut() {
            if *k == V::Uint(5) {
                let mut s = x.as_bytes().unwrap().to_vec();
                s[3] ^= 1;
                *x = V::Bytes(s);
            }
        }
    }
    let bad_enc = sign1(&owner(), cose::CT_JOINREQ, &cbor::encode(&p2));
    assert_eq!(approve::check_joinreq(&rec, &bad_enc), Err(Error::Invalid("sig_enc")));
    // the node already in the record under another owner (creator or member) -> refused
    let me = |state, owner_pub: [u8; 65]| Member {
        dac_pub_hash: dev_dac_hash(&v),
        ecdh_pub: [4; 65],
        name: "x".into(),
        owner_pub,
        owner_enc_pub: [4; 65],
        device_id: None,
        state,
        prev_country: None,
    };
    for state in [MemberState::Applied, MemberState::Joining, MemberState::Approved] {
        let mut r2 = rec.clone();
        r2.list = Some(vec![me(state, [4; 65])]);
        assert_eq!(approve::check_joinreq(&r2, &jr), Err(Error::AlreadyMember), "{state:?}");
    }
    // the same owner's approved entry -> allowed (re-approval)
    let mut r3 = rec.clone();
    r3.list = Some(vec![me(MemberState::Approved, pub65(&owner()))]);
    assert!(approve::check_joinreq(&r3, &jr).unwrap().replaces_approved);
    // ... but not the same owner's applied entry
    r3.list = Some(vec![me(MemberState::Applied, pub65(&owner()))]);
    assert_eq!(approve::check_joinreq(&r3, &jr), Err(Error::AlreadyMember));
}

// ---- M6 SAS -----------------------------------------------------------------------------------------------------

#[test]
fn m6_sas_covers_the_whole_invite_and_request() {
    let v = vectors();
    let (ad, md) = (Disk::new(), Disk::new());
    let inv = invite(&v, &ad);
    let (_, sas, _) = request(&v, &md, &inv, "客廳");
    // another owner_enc_pub (same invite, same node) -> another request hash -> another SAS
    let md2 = Disk::new();
    let mut i = jr_input(&v, &inv, "客廳", None);
    i.owner_enc_pub = pub65(&sk(NODE_ECDH_PRIV));
    let (f, a) = JoinReqFlow::start(i);
    let sas2 = out(&drive(&md2, f, a, false)).1;
    assert_ne!(sas, sas2);
    // another invite (same network, same node, same keys) -> another SAS
    let inv2 = invite(&v, &ad);
    let (_, sas3, _) = request(&v, &Disk::new(), &inv2, "客廳");
    assert_ne!(sas, sas3);
}

// ---- M7 net_make_invite / net_approve -----------------------------------------------------------------------------

#[test]
fn m7_invite_persists_before_output_and_refuses_duplicates() {
    let v = vectors();
    let ad = Disk::new();
    ad.put(REL, &netrec::encode(&admin_record(&v)));
    let (g, p) = ad.get(REL).unwrap();
    let id: [u8; 16] = hex::decode(INVITE_ID).unwrap().try_into().unwrap();
    // written elsewhere between reading and writing -> no output
    let (f, a) = InviteFlow::start_with_id(&p, g, &pub65(&admin()), id);
    let r = drive(&ad, f, a, true);
    assert_eq!(r.end, Some(End::PersistFailed(None)));
    // the vectors' invite: key 12 holds its OBJECT_HASH, unused
    let (g, p) = ad.get(REL).unwrap();
    let (f, a) = InviteFlow::start_with_id(&p, g, &pub65(&admin()), id);
    let hex = out(&drive(&ad, f, a, false)).0;
    assert_eq!(hex, v["cose"]["qr_invite_object"].as_str().unwrap());
    let rec = netrec::decode(&ad.get(REL).unwrap().1).unwrap();
    let ih = cose::object_hash(&h(&v["cose"]["invite_remote"])).unwrap();
    assert_eq!(rec.invites, Some(vec![InviteRec { hash: ih, kind: 1, used: false }]));
    // the same invite hash again -> refused, nothing written
    let (g, p) = ad.get(REL).unwrap();
    let (f, a) = InviteFlow::start_with_id(&p, g, &pub65(&admin()), id);
    let r = drive(&ad, f, a, false);
    assert_eq!(refused(&r), Error::DuplicateInvite);
    assert!(r.writes.is_empty());
}

#[test]
fn m7_admin_preconditions() {
    let v = vectors();
    let ad = Disk::new();
    let mut rec = admin_record(&v);
    rec.state = "pending".into();
    ad.put(REL, &netrec::encode(&rec));
    let (g, p) = ad.get(REL).unwrap();
    let (f, a) = InviteFlow::start(&p, g, &pub65(&admin()));
    let r = drive(&ad, f, a, false);
    assert_eq!((refused(&r), r.signs.len(), r.writes.len()), (Error::NotApplied, 0, 0));
    // this phone's admin key not in the netcfg admins
    let (f, a) = InviteFlow::start(&netrec::encode(&admin_record(&v)), 1, &pub65(&owner()));
    assert_eq!(refused(&drive(&ad, f, a, false)), Error::NotAdmin);
    // 16 members, approved ones counted
    let mut full = admin_record(&v);
    full.list = Some((0..16u8).map(|i| Member {
        dac_pub_hash: [i; 32],
        ecdh_pub: [4; 65],
        name: "x".into(),
        owner_pub: [4; 65],
        owner_enc_pub: [4; 65],
        device_id: None,
        state: if i % 2 == 0 { MemberState::Approved } else { MemberState::Applied },
        prev_country: None,
    }).collect());
    let (f, a) = InviteFlow::start(&netrec::encode(&full), 1, &pub65(&admin()));
    assert_eq!(refused(&drive(&ad, f, a, false)), Error::Full);
}

#[test]
fn m7_approve_reruns_the_checks_and_writes_before_output() {
    let v = vectors();
    let (ad, md) = (Disk::new(), Disk::new());
    let inv = invite(&v, &ad);
    let (jr_hex, _, _) = request(&v, &md, &inv, "客廳");
    let (g, p) = ad.get(REL).unwrap();
    // a hash other than the one the admin saw -> no output, nothing signed
    let (f, a) = ApproveFlow::start(&p, g, &jr_hex, &[0; 32], &pub65(&admin()));
    let r = drive(&ad, f, a, false);
    assert_eq!((refused(&r), r.signs.len()), (Error::HashMismatch, 0));
    // the record changed between reading and writing -> no output
    let c = approve::check_joinreq(&netrec::decode(&p).unwrap(), &invite::qr_object(&jr_hex, 2).unwrap()).unwrap();
    let (f, a) = ApproveFlow::start(&p, g, &jr_hex, &c.jr.hash, &pub65(&admin()));
    let r = drive(&ad, f, a, true);
    assert_eq!(r.end, Some(End::PersistFailed(None)));
    // the real thing: 2 admin signatures, key 12 used, an approved entry
    let r = approve(&ad, &jr_hex);
    assert_eq!(r.signs, ["admin", "admin"]);
    let rec = netrec::decode(&ad.get(REL).unwrap().1).unwrap();
    assert!(rec.invites.as_ref().unwrap().iter().all(|i| i.used));
    let me = rec.members().unwrap().into_iter().find(|m| m.dac_pub_hash == dev_dac_hash(&v)).unwrap();
    assert_eq!((me.state, me.owner_pub, me.name.as_str()), (MemberState::Approved, pub65(&owner()), "客廳"));
    // the used invite -> a second approval of the same request is refused
    let (g, p) = ad.get(REL).unwrap();
    let (f, a) = ApproveFlow::start(&p, g, &jr_hex, &c.jr.hash, &pub65(&admin()));
    let r = drive(&ad, f, a, false);
    assert_eq!((refused(&r), r.signs.len(), r.writes.len()), (Error::InviteUsed, 0, 0));
}

#[test]
fn m7_key_12_survives_confirm_and_forget() {
    let v = vectors();
    let ad = Disk::new();
    let _ = invite(&v, &ad);
    let mut rec = netrec::decode(&ad.get(REL).unwrap().1).unwrap();
    let inv = rec.invites.clone();
    assert!(inv.is_some());
    rec.state = "pending".into();
    let info = m(vec![(9, V::Uint(1)), (10, V::Bytes(rec.base.net_id.to_vec())), (11, V::Bool(false))]);
    netrec::confirm(&mut rec, &info).unwrap();
    let mut rec = netrec::decode(&netrec::encode(&rec)).unwrap();
    assert_eq!(rec.invites, inv, "confirm keeps key 12");
    let mut l = rec.members().unwrap();
    l.push(Member { dac_pub_hash: [7; 32], ecdh_pub: [4; 65], name: "x".into(), owner_pub: [4; 65], owner_enc_pub: [4; 65], device_id: None, state: MemberState::Joining, prev_country: None });
    rec.list = Some(l);
    netrec::forget_joining(&mut rec, &[7; 32]).unwrap();
    assert_eq!(netrec::decode(&netrec::encode(&rec)).unwrap().invites, inv, "forget keeps key 12");
}

// ---- M8 import --------------------------------------------------------------------------------------------------

#[test]
fn m8_the_whole_path_imports() {
    let v = vectors();
    let (_, md, ap, sas) = to_approval(&v);
    assert_eq!(approve::approval_net_id(&ap).unwrap(), "a5faaf844ee7c02b2909617cadbbd809");
    let (got, gen) = match prepare(&md, &ap).unwrap() {
        Prepared::Ready { sas, pend_gen, .. } => (sas, pend_gen),
        x => panic!("{x:?}"),
    };
    assert_eq!((got.as_str(), gen), (sas.as_str(), 1), "7a shows the SAS the joiner's request had");
    let x = import_all(&md, &ap);
    assert_eq!(x.net_root.to_vec(), h(&v["keys"]["net_root"]));
    let me = x.me.unwrap();
    assert_eq!((me.state, me.dac_pub_hash, me.name.as_str()), (MemberState::Joining, dev_dac_hash(&v), "客廳"));
    assert!(md.get(PEND).is_none(), "mpend removed after the import");
}

/// re-sign an approval whose bundle was edited (`f` on the decoded bundle map)
fn edit_bundle(ap: &str, f: impl FnOnce(&mut Vec<(V, V)>)) -> String {
    let mut b = cbor::decode(&invite::qr_object(ap, 3).unwrap()).unwrap();
    let V::Map(e) = &mut b else { panic!() };
    f(e);
    invite::qr_hex(3, &cbor::encode(&b))
}
fn set(e: &mut Vec<(V, V)>, k: u64, x: V) {
    e.retain(|(kk, _)| *kk != V::Uint(k));
    e.push((V::Uint(k), x));
}
fn item(b: &[u8]) -> V {
    cbor::decode(b).unwrap()
}
/// the bundle's Sign1 under key `k`, payload edited by `f`, re-signed by `by`
fn resign(ap: &str, k: u64, ctype: &str, by: &p256::ecdsa::SigningKey, f: impl FnOnce(&mut Vec<(V, V)>)) -> String {
    let b = cbor::decode(&invite::qr_object(ap, 3).unwrap()).unwrap();
    let mut p = netrec::sign1_payload(&cbor::encode(b.get(k).unwrap())).unwrap();
    let V::Map(e) = &mut p else { panic!() };
    f(e);
    let s = sign1(by, ctype, &cbor::encode(&p));
    edit_bundle(ap, |e| set(e, k, item(&s)))
}

#[test]
fn m8_refusals_write_nothing() {
    let v = vectors();
    let (_, md, ap, sas) = to_approval(&v);
    let stranger = sk(OWNER_ENC_PRIV);
    let other_cfg = {
        let mut p = cbor::decode(&h(&v["cose"]["net_config"]["payload"])).unwrap();
        if let V::Map(e) = &mut p {
            set(e, 4, V::Text("別的".into()));
        }
        sign1(&admin(), cose::CT_NETCFG, &cbor::encode(&p))
    };
    let arms: Vec<(&str, String)> = vec![
        ("key 1 != the request's netcfg", edit_bundle(&ap, |e| set(e, 1, item(&other_cfg)))),
        ("members not by the admins", resign(&ap, 2, cose::CT_MEMBERS, &stranger, |_| {})),
        ("secrets not by the admins", resign(&ap, 3, cose::CT_SECRETS, &stranger, |_| {})),
        ("msecrets not by the admins", resign(&ap, 4, cose::CT_MSECRETS, &stranger, |_| {})),
        ("same admin key, another net_id", resign(&ap, 3, cose::CT_SECRETS, &admin(), |e| set(e, 1, V::Bytes(vec![9; 16])))),
        ("version mismatch", resign(&ap, 4, cose::CT_MSECRETS, &admin(), |e| set(e, 2, V::Uint(2)))),
        ("secrets for another node", resign(&ap, 3, cose::CT_SECRETS, &admin(), |e| set(e, 3, V::Bytes(vec![1; 32])))),
        ("msecrets for another phone", resign(&ap, 4, cose::CT_MSECRETS, &admin(), |e| set(e, 3, V::Bytes(vec![1; 32])))),
    ];
    for (what, bad) in arms {
        assert!(prepare(&md, &bad).is_err(), "7a: {what}");
        let r = approve::import(&bad, (1, &md.get(PEND).unwrap().1), 1, None, &[0; 32], &sas);
        assert!(r.is_err(), "7c: {what}");
    }
    assert!(md.get(MNET).is_none());
    // no mpend at all
    assert_eq!(prepare(&Disk::new(), &ap), Err(Error::NoRequest));
}

#[test]
fn m8_7c_needs_the_7a_generation_the_confirmed_sas_a_curve_point_and_the_aead() {
    let v = vectors();
    let (_, md, ap, sas) = to_approval(&v);
    // [synthetic: a SAS collision, ~1e-6] mpend rewritten with the same content after 7a (generation + 1)
    let (g, p) = md.get(PEND).unwrap();
    md.cas(PEND, g, &p).unwrap();
    assert_eq!(import(&md, &ap, g, &sas), Err(Error::Stale));
    let g = md.get(PEND).unwrap().0;
    // a SAS other than the request's
    assert_eq!(import(&md, &ap, g, "000000").map(|_| ()), Err(Error::SasMismatch));
    // a wrong z -> AEAD fails
    let (gp, pp) = md.get(PEND).unwrap();
    assert_eq!(approve::import(&ap, (gp, &pp), gp, None, &[7; 32], &sas).map(|_| ()), Err(Error::Aead));
    // an ephemeral key that is not on the curve
    let bad_eph = resign(&ap, 4, cose::CT_MSECRETS, &admin(), |e| {
        let (_, enc) = e.iter_mut().find(|(k, _)| *k == V::Uint(4)).unwrap();
        let V::Tag(96, a) = enc else { panic!() };
        let V::Array(a) = a.as_mut() else { panic!() };
        let V::Array(r) = &mut a[3] else { panic!() };
        let V::Array(r0) = &mut r[0] else { panic!() };
        let V::Map(ru) = &mut r0[1] else { panic!() };
        let V::Map(ck) = &mut ru[0].1 else { panic!() };
        for (k, x) in ck.iter_mut() {
            if *k == V::Nint(2) {
                *x = V::Bytes(vec![1; 32]);
            }
        }
    });
    assert!(prepare(&md, &bad_eph).is_err());
    assert!(approve::import(&bad_eph, (gp, &pp), gp, None, &[0; 32], &sas).is_err());
    // a plaintext with another key than {2: net_root}
    let ms_extra = {
        let pend = Pend::decode(&pp).unwrap();
        let cfg = netrec::netcfg_of(&netrec::sign1_payload(&pend.netcfg).unwrap()).unwrap();
        let plain = cbor::encode(&m(vec![(2, V::Bytes(vec![5; 32])), (3, V::Uint(1))]));
        let e = cose::encrypt_to(&plain, cose::LABEL_MSECRETS, &owner_enc_pub(), &pend.owner_enc_hash, &cfg.net_id, 1).unwrap();
        sign1(&admin(), cose::CT_MSECRETS, &cose::net_secrets_payload(&cfg.net_id, 1, &pend.owner_enc_hash, &e.object))
    };
    let extra = edit_bundle(&ap, |e| set(e, 4, item(&ms_extra)));
    let eph = match prepare(&md, &extra).unwrap() {
        Prepared::Ready { eph_pub, .. } => eph_pub,
        x => panic!("{x:?}"),
    };
    let z = ecdh_z(OWNER_ENC_PRIV, &eph);
    assert!(matches!(approve::import(&extra, (gp, &pp), gp, None, &z, &sas), Err(Error::Invalid(_))));
    assert!(md.get(MNET).is_none());
}

/// an mnet already there, built from `cfg` (netcfg Sign1) with own entry `me`
fn stored_mnet(md: &Disk, cfg: Vec<u8>, version: u32, me: Option<Member>) {
    let x = MNet { net_id: h(&vectors()["keys"]["net_id"]).try_into().unwrap(), version, netcfg: cfg, members: vec![], secrets: vec![], net_root: [1; 32], me, invite_hash: [0; 32] };
    md.put(MNET, &x.encode());
}

/// a pend whose netcfg is `cfg` (the rest from the current one)
fn pend_with_cfg(md: &Disk, cfg: Vec<u8>) {
    let (_, p) = md.get(PEND).unwrap();
    let mut pend = Pend::decode(&p).unwrap();
    pend.netcfg = cfg;
    md.put(PEND, &pend.encode());
}

/// a version-`ver` netcfg of the vectors' network, prev `prev`, admins `admins`, signed by `by`
fn cfg_v(ver: u64, prev: Option<[u8; 32]>, net_id: [u8; 16], by: &p256::ecdsa::SigningKey) -> Vec<u8> {
    let mut p = cbor::decode(&h(&vectors()["cose"]["net_config"]["payload"])).unwrap();
    if let V::Map(e) = &mut p {
        set(e, 1, V::Bytes(net_id.to_vec()));
        set(e, 2, V::Uint(ver));
        set(e, 3, prev.map_or(V::Null, |x| V::Bytes(x.to_vec())));
    }
    sign1(by, cose::CT_NETCFG, &cbor::encode(&p))
}

#[test]
fn m8_existing_mnet_chain_rules() {
    let v = vectors();
    let id: [u8; 16] = h(&v["keys"]["net_id"]).try_into().unwrap();
    let v1 = h(&v["cose"]["net_config"]["sign1"]);
    let h1 = cose::object_hash(&v1).unwrap();
    let stranger = sk(OWNER_ENC_PRIV);
    let try_with = |stored: Vec<u8>, stored_ver: u32, new_cfg: Option<Vec<u8>>| {
        let (_, md, ap, _) = to_approval(&v);
        stored_mnet(&md, stored, stored_ver, None);
        if let Some(c) = new_cfg {
            pend_with_cfg(&md, c);
        }
        prepare(&md, &ap)
    };
    // the same netcfg byte for byte -> fine
    assert!(matches!(try_with(v1.clone(), 1, None), Ok(Prepared::Ready { .. })));
    // stored under foreign admins with the same version, other bytes -> "another network under the same number"
    assert_eq!(try_with(cfg_v(1, None, id, &stranger), 1, None), Err(Error::SameVersionDifferent));
    let _ = h1;
}

/// the approval's three Sign1s re-signed (admin) at `ver`
fn approval_at(ap: &str, ver: u64) -> String {
    let a = resign(ap, 2, cose::CT_MEMBERS, &admin(), |e| set(e, 2, V::Uint(ver)));
    let a = resign(&a, 3, cose::CT_SECRETS, &admin(), |e| set(e, 2, V::Uint(ver)));
    resign(&a, 4, cose::CT_MSECRETS, &admin(), |e| set(e, 2, V::Uint(ver)))
}

#[test]
fn m8_two_or_more_versions_ahead_is_too_old() {
    let v = vectors();
    let id: [u8; 16] = h(&v["keys"]["net_id"]).try_into().unwrap();
    let v1 = h(&v["cose"]["net_config"]["sign1"]);
    let (_, md, ap, _) = to_approval(&v);
    stored_mnet(&md, v1.clone(), 1, None);
    pend_with_cfg(&md, cfg_v(3, Some([1; 32]), id, &admin()));
    assert_eq!(prepare(&md, &approval_at(&ap, 3)), Err(Error::TooOld));
}

#[test]
fn m8_chain_rule_checked_before_the_approval() {
    // the chain rule on its own (the approval re-signed at version 2, so only the chain decides)
    let v = vectors();
    let id: [u8; 16] = h(&v["keys"]["net_id"]).try_into().unwrap();
    let v1 = h(&v["cose"]["net_config"]["sign1"]);
    let h1 = cose::object_hash(&v1).unwrap();
    let v2_approval = |ap: &str| approval_at(ap, 2);
    let arm = |new_cfg: Vec<u8>| {
        let (_, md, ap, _) = to_approval(&v);
        stored_mnet(&md, v1.clone(), 1, None);
        pend_with_cfg(&md, new_cfg);
        prepare(&md, &v2_approval(&ap))
    };
    assert!(matches!(arm(cfg_v(2, Some(h1), id, &admin())), Ok(Prepared::Ready { .. })), "next version, chained");
    assert_eq!(arm(cfg_v(2, Some([3; 32]), id, &admin())), Err(Error::Invalid("not the next version of the stored network")), "prev_hash");
    assert_eq!(arm(cfg_v(2, Some(h1), [8; 16], &admin())).map(|_| ()).unwrap_err(), Error::Invalid("another net_id / version"));
    assert!(arm(cfg_v(2, Some(h1), id, &sk(OWNER_ENC_PRIV))).is_err(), "foreign admins");
}

#[test]
fn m8_chain_net_id_checked() {
    // version + 1 with another net_id, the approval matching it: only the chain rule can refuse
    let v = vectors();
    let v1 = h(&v["cose"]["net_config"]["sign1"]);
    let h1 = cose::object_hash(&v1).unwrap();
    let (_, md, ap, _) = to_approval(&v);
    stored_mnet(&md, v1, 1, None);
    let other: [u8; 16] = [8; 16];
    pend_with_cfg(&md, cfg_v(2, Some(h1), other, &admin()));
    let a = resign(&ap, 2, cose::CT_MEMBERS, &admin(), |e| {
        set(e, 1, V::Bytes(other.to_vec()));
        set(e, 2, V::Uint(2))
    });
    let a = resign(&a, 3, cose::CT_SECRETS, &admin(), |e| {
        set(e, 1, V::Bytes(other.to_vec()));
        set(e, 2, V::Uint(2))
    });
    let a = resign(&a, 4, cose::CT_MSECRETS, &admin(), |e| {
        set(e, 1, V::Bytes(other.to_vec()));
        set(e, 2, V::Uint(2))
    });
    assert_eq!(prepare(&md, &a), Err(Error::Invalid("not the next version of the stored network")));
}

#[test]
fn m8_own_entry_carry_rules() {
    let v = vectors();
    let v1 = h(&v["cose"]["net_config"]["sign1"]);
    let e = |dac: [u8; 32], state, prev: Option<&str>| Member {
        dac_pub_hash: dac,
        ecdh_pub: [4; 65],
        name: "old".into(),
        owner_pub: [4; 65],
        owner_enc_pub: [4; 65],
        device_id: None,
        state,
        prev_country: prev.map(str::to_string),
    };
    // the same DAC -> state and prev_country carried
    let (_, md, ap, _) = to_approval(&v);
    stored_mnet(&md, v1.clone(), 1, Some(e(dev_dac_hash(&v), MemberState::Joining, Some("JP"))));
    let x = import_all(&md, &ap);
    let me = x.me.unwrap();
    assert_eq!((me.state, me.prev_country.as_deref(), me.name.as_str()), (MemberState::Joining, Some("JP"), "old"));
    // another DAC, joining or with a prev_country -> refused
    for (state, prev) in [(MemberState::Joining, None), (MemberState::Applied, Some("JP"))] {
        let (_, md, ap, _) = to_approval(&v);
        stored_mnet(&md, v1.clone(), 1, Some(e([9; 32], state, prev)));
        assert_eq!(prepare(&md, &ap), Err(Error::PreviousNode), "{state:?} {prev:?}");
    }
    // another DAC, applied -> a fresh joining entry
    let (_, md, ap, _) = to_approval(&v);
    stored_mnet(&md, v1, 1, Some(e([9; 32], MemberState::Applied, None)));
    let me = import_all(&md, &ap).me.unwrap();
    assert_eq!((me.state, me.prev_country, me.dac_pub_hash), (MemberState::Joining, None, dev_dac_hash(&v)));
}

#[test]
fn m8_forged_invite_and_old_requests() {
    let v = vectors();
    // a forged invite I' with the same net_id replaces the request; the real approval is refused
    let (_, md, ap, _) = to_approval(&v);
    let id: [u8; 16] = h(&v["keys"]["net_id"]).try_into().unwrap();
    let evil = sk(OWNER_ENC_PRIV);
    // the forger's own version-1 netcfg with the same net_id, listing the forger as admin
    let mut fp = cbor::decode(&h(&v["cose"]["net_config"]["payload"])).unwrap();
    if let V::Map(e) = &mut fp {
        set(e, 8, V::Array(vec![V::Bytes(pub65(&evil).to_vec())]));
    }
    let forged_cfg = sign1(&evil, cose::CT_NETCFG, &cbor::encode(&fp));
    let i2 = sign1(&evil, cose::CT_INVITE, &invite::invite_payload(&id, &[2; 16], item(&forged_cfg), &pub65(&evil)));
    let i2_hex = invite::qr_hex(1, &i2);
    let (_, sas_forged, _) = request(&v, &md, &i2_hex, "客廳");
    assert!(prepare(&md, &ap).is_err(), "the real approval does not fit the forged request");
    // the forger's approval: 7a shows SAS(I', J'); the program accepts it with that SAS (only the human check stops
    // it: §5-5) and refuses any other confirmed SAS
    let ad2 = Disk::new();
    let mut rec = admin_record(&v);
    rec.base.netcfg = forged_cfg.clone();
    rec.base.members = sign1(&evil, cose::CT_MEMBERS, &h(&v["cose"]["member_list"]["payload"]));
    rec.invites = Some(vec![InviteRec { hash: cose::object_hash(&i2).unwrap(), kind: 1, used: false }]);
    ad2.put(REL, &netrec::encode(&rec));
    let jr_hex = invite::qr_hex(2, &Pend::decode(&md.get(PEND).unwrap().1).unwrap().joinreq);
    let (g, p) = ad2.get(REL).unwrap();
    let c = approve::check_joinreq(&netrec::decode(&p).unwrap(), &invite::qr_object(&jr_hex, 2).unwrap()).unwrap();
    let (mut f, mut a) = ApproveFlow::start(&p, g, &jr_hex, &c.jr.hash, &pub65(&evil));
    let ap_forged = loop {
        a = match a {
            Action::SignAdmin { tbs } => f.signed(&der(&evil, &tbs)).unwrap(),
            Action::Persist { rel, plain, expected_gen } => {
                ad2.cas(&rel, expected_gen, &plain).unwrap();
                f.persisted().unwrap()
            }
            Action::Done(End::Out { hex, .. }) => break hex,
            x => panic!("{x:?}"),
        };
    };
    match prepare(&md, &ap_forged).unwrap() {
        Prepared::Ready { sas, .. } => assert_eq!(sas, sas_forged),
        x => panic!("{x:?}"),
    }
    let g = md.get(PEND).unwrap().0;
    assert_eq!(import(&md, &ap_forged, g, "123456").map(|_| ()), Err(Error::SasMismatch));
    assert!(import(&md, &ap_forged, g, &sas_forged).is_ok(), "accepted with the SAS on screen: only the human check");
}

#[test]
fn m8_an_old_requests_approval_imports_with_another_sas() {
    let v = vectors();
    let (ad, md) = (Disk::new(), Disk::new());
    let inv = invite(&v, &ad);
    let (jr1, _, _) = request(&v, &md, &inv, "客廳");
    let ap1 = out(&approve(&ad, &jr1)).0;
    // a new request for the same invite (pend unreadable -> re-signed): same netcfg / DAC / owner_enc
    let (f, a) = JoinReqFlow::start(JoinReqInput { pend_plain: None, pend_gen: 1, ..jr_input(&v, &inv, "客廳", None) });
    let sas_new = out(&drive(&md, f, a, false)).1;
    match prepare(&md, &ap1).unwrap() {
        Prepared::Ready { sas, .. } => assert_eq!(sas, sas_new, "the SAS shown is the current request's: the admin's screen had another one"),
        x => panic!("{x:?}"),
    }
    assert!(import_all(&md, &ap1).me.is_some());
}

#[test]
fn m8_repasting_after_the_import() {
    let v = vectors();
    let (_, md, ap, _) = to_approval(&v);
    import_all(&md, &ap);
    assert_eq!(prepare(&md, &ap), Ok(Prepared::AlreadyImported));
    // the own entry dropped (a definite join failure) -> a new invite is needed
    let (g, p) = md.get(MNET).unwrap();
    let mut x = MNet::decode(&p).unwrap();
    x.me = None;
    md.cas(MNET, g, &x.encode()).unwrap();
    assert_eq!(prepare(&md, &ap), Ok(Prepared::NeedsNewInvite));
    // another approval of the same network (other secrets bytes: a fresh ephemeral key) -> no request
    let (_, _, ap_b, _) = to_approval(&v);
    assert_eq!(prepare(&md, &ap_b), Err(Error::NoRequest), "secrets differ from the stored ones");
}

// ---- M10 approved -----------------------------------------------------------------------------------------------

#[test]
fn m10_approved_entries() {
    let v = vectors();
    let (ad, md) = (Disk::new(), Disk::new());
    let inv = invite(&v, &ad);
    let (jr, _, _) = request(&v, &md, &inv, "客廳");
    approve(&ad, &jr);
    let mut rec = netrec::decode(&ad.get(REL).unwrap().1).unwrap();
    // confirm does not upgrade an approved entry
    let info = m(vec![(9, V::Uint(1)), (10, V::Bytes(rec.base.net_id.to_vec())), (11, V::Bool(false))]);
    netrec::confirm(&mut rec, &info).unwrap();
    let st = |r: &NetRec| r.members().unwrap().into_iter().find(|m| m.dac_pub_hash == dev_dac_hash(&v)).map(|m| m.state);
    assert_eq!(st(&rec), Some(MemberState::Approved));
    // forget accepts it
    let gone = netrec::forget_joining(&mut rec, &dev_dac_hash(&v)).unwrap();
    assert_eq!(gone.state, MemberState::Approved);
    assert_eq!(st(&rec), None);
}

// ---- M12 lifecycle ----------------------------------------------------------------------------------------------

#[test]
fn m12_rebuilt_sessions_and_paths() {
    let v = vectors();
    let (ad, md) = (Disk::new(), Disk::new());
    let inv = invite(&v, &ad);
    let (hex, sas, _) = request(&v, &md, &inv, "客廳");
    // "show the request again" from the store only
    let shown = invite::pend_view(&md.get(PEND).unwrap().1).unwrap();
    assert_eq!(shown, End::Out { hex: hex.clone(), sas: sas.clone(), name: "客廳".into(), renewed: false });
    // the mpend opened under another path does not open
    let r = md.0.read(PEND).unwrap().unwrap();
    assert!(open(MNET, r.generation, &r.sealed).is_none());
    // after the import, a rebuilt session finds the network to join ("繼續加入"): key 7 joining
    let ap = out(&approve(&ad, &hex)).0;
    import_all(&md, &ap);
    let x = MNet::decode(&md.get(MNET).unwrap().1).unwrap();
    assert_eq!(x.me.unwrap().state, MemberState::Joining);
}

#[test]
fn m12_a_new_request_between_import_and_removal_is_removed() {
    // accepted fail-closed: written mnet, a new request lands before mpend is removed -> the new one goes; request again
    let v = vectors();
    let (ad, md, ap, _) = to_approval(&v);
    let (sas, gen) = match prepare(&md, &ap).unwrap() {
        Prepared::Ready { sas, pend_gen, .. } => (sas, pend_gen),
        x => panic!("{x:?}"),
    };
    let (plain, _, mg) = import(&md, &ap, gen, &sas).unwrap();
    md.cas(MNET, mg, &plain).unwrap();
    let inv2 = invite(&v, &ad);
    request(&v, &md, &inv2, "客廳");
    md.0.remove(PEND).unwrap();
    assert!(md.get(PEND).is_none());
    let (_, _, r) = request(&v, &md, &inv2, "客廳");
    assert_eq!(r.writes, [(PEND.to_string(), 0)], "requested again from scratch");
}

// ---- M13 names --------------------------------------------------------------------------------------------------

#[test]
fn m13_names() {
    assert!(invite::check_name("客廳").is_ok());
    assert!(invite::check_name(&"a".repeat(32)).is_ok());
    assert_eq!(invite::check_name(&"a".repeat(33)), Err(Error::Name));
    // 11 CJK characters = 33 bytes: refused although only 11 characters
    assert_eq!(invite::check_name(&"客".repeat(11)), Err(Error::Name));
    assert_eq!(invite::check_name("abc\u{202E}def"), Err(Error::Name));
    assert_eq!(invite::check_name("abc\u{200B}"), Err(Error::Name));
    assert_eq!(invite::check_name("a\nb"), Err(Error::Name));
    assert_eq!(invite::check_name("a\u{7}b"), Err(Error::Name));
}

#[test]
fn records_round_trip() {
    let p = Pend { invite_hash: [1; 32], netcfg: vec![2], joinreq_hash: [3; 32], dac_hash: [4; 32], owner_enc_hash: [5; 32], device_id: "d".into(), joinreq: vec![7] };
    assert_eq!(Pend::decode(&p.encode()).unwrap(), p);
    let x = MNet { net_id: [1; 16], version: 1, netcfg: vec![2], members: vec![3], secrets: vec![4], net_root: [5; 32], me: None, invite_hash: [6; 32] };
    assert!(MNet::decode(&x.encode()).unwrap() == x);
    assert_eq!(mrec::pend_path(&[0xab; 16]), format!("mpend/{}", "ab".repeat(16)));
}
