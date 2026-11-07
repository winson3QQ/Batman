//! conn: requests and responses over a real Noise NX session against a snow responder standing in for provd.

use batman_proto::cbor::{self, Value as V};
use batman_proto::conn::{Conn, Error};
use batman_proto::envelope::Outcome;
use batman_proto::{frame, noise};

const FL: usize = 244; // CTRL key 3

struct Node {
    t: snow::TransportState,
    rx: frame::Reassembler,
}

fn pair() -> (Conn, Node) {
    let p: snow::params::NoiseParams = "Noise_NX_25519_ChaChaPoly_SHA256".parse().unwrap();
    let pro = noise::prologue(noise::Mode::Nx, Some("abcdef012345678901"));
    let kp = snow::Builder::new(p.clone()).generate_keypair().unwrap();
    let mut r = snow::Builder::new(p).prologue(&pro).unwrap().local_private_key(&kp.private).unwrap().build_responder().unwrap();
    let mut i = noise::Initiator::new(noise::Mode::Nx, Some("abcdef012345678901"), None).unwrap();
    let m1 = i.msg1().unwrap();
    let mut buf = vec![0u8; 65535];
    r.read_message(&m1, &mut buf).unwrap();
    let n = r.write_message(b"node_cert", &mut buf).unwrap();
    let (payload, s) = i.read_msg2(&buf[..n]).unwrap();
    assert_eq!(payload, b"node_cert");
    let h: Vec<u8> = r.get_handshake_hash().to_vec();
    let c = Conn::new(s, FL);
    assert_eq!(c.h().to_vec(), h, "both ends hold the same channel binding");
    (c, Node { t: r.into_transport_mode().unwrap(), rx: frame::Reassembler::new(FL, 8192) })
}

impl Node {
    /// the request envelope the node reads from the frames
    fn read(&mut self, frames: &[Vec<u8>]) -> V {
        let mut msg = None;
        for f in frames {
            assert!(f.len() <= FL);
            msg = self.rx.push(f).unwrap();
        }
        let ct = msg.expect("frames complete a message");
        let mut buf = vec![0u8; 65535];
        let n = self.t.read_message(&ct, &mut buf).unwrap();
        cbor::decode(&buf[..n]).unwrap()
    }
    fn send(&mut self, env: &V) -> Vec<Vec<u8>> {
        let mut buf = vec![0u8; 65535];
        let n = self.t.write_message(&cbor::encode(env), &mut buf).unwrap();
        frame::split(&buf[..n], FL).unwrap()
    }
}

fn m(pairs: Vec<(u64, V)>) -> V {
    V::Map(pairs.into_iter().map(|(k, v)| (V::Uint(k), v)).collect())
}
fn ok(id: u64, body: V) -> V {
    m(vec![(1, V::Uint(id)), (3, body), (4, V::Uint(0))])
}
fn feed(c: &mut Conn, frames: &[Vec<u8>]) -> Result<Option<Outcome>, Error> {
    let mut out = Ok(None);
    for f in frames {
        out = c.on_frame(f);
        if out.is_err() {
            break;
        }
    }
    out
}

#[test]
fn request_response_ids_increase() {
    let (mut c, mut n) = pair();
    for want in 1..=3u64 {
        let (id, frames) = c.request("info", m(vec![])).unwrap();
        assert_eq!(id, want);
        let req = n.read(&frames);
        assert_eq!(req.get(1).and_then(|x| x.as_uint()), Some(want));
        assert_eq!(req.get(2).and_then(|x| x.as_text()), Some("info"));
        let body = m(vec![(7, V::Uint(0))]);
        assert_eq!(feed(&mut c, &n.send(&ok(id, body.clone()))), Ok(Some(Outcome::Ok(body))));
    }
}

#[test]
fn large_request_spans_frames_and_stays_one_message() {
    let (mut c, mut n) = pair();
    let big = m(vec![(1, V::Bytes(vec![0x5a; 3000]))]);
    let (_, frames) = c.request("network/join", big.clone()).unwrap();
    assert!(frames.len() > 10);
    let req = n.read(&frames);
    assert_eq!(req.get(3), Some(&big));
    assert!(req.get(6).is_none(), "fits in 8192: not chunked");
}

#[test]
fn one_request_at_a_time() {
    let (mut c, _n) = pair();
    c.request("info", m(vec![])).unwrap();
    assert_eq!(c.request("info", m(vec![])).err(), Some(Error::Busy));
    assert!(!c.is_closed(), "Busy is the caller's mistake, the connection is still good");
}

#[test]
fn every_error_closes_the_connection() {
    // a response to another id
    let (mut c, mut n) = pair();
    let (id, f) = c.request("info", m(vec![])).unwrap();
    n.read(&f);
    assert!(matches!(feed(&mut c, &n.send(&ok(id + 1, m(vec![])))), Err(Error::Envelope(_))));
    assert!(c.is_closed());
    assert_eq!(c.request("info", m(vec![])).err(), Some(Error::Closed));
    assert_eq!(c.on_frame(&[3, 0, 0]), Err(Error::Closed));

    // a tampered ciphertext
    let (mut c, mut n) = pair();
    let (id, f) = c.request("info", m(vec![])).unwrap();
    n.read(&f);
    let mut fr = n.send(&ok(id, m(vec![])));
    let last = fr.last_mut().unwrap();
    let k = last.len() - 1;
    last[k] ^= 1;
    assert!(matches!(feed(&mut c, &fr), Err(Error::Noise(_))));
    assert!(c.is_closed());

    // a message with nothing outstanding
    let (mut c, mut n) = pair();
    assert_eq!(feed(&mut c, &n.send(&ok(1, m(vec![])))), Err(Error::Unsolicited));
    assert!(c.is_closed());

    // a frame violation (no start flag)
    let (mut c, _n) = pair();
    c.request("info", m(vec![])).unwrap();
    assert!(matches!(c.on_frame(&[0x02, 0, 0, 1]), Err(Error::Frame(_))));
    assert!(c.is_closed());

    // a chunked response (S1 refuses, design §5.5)
    let (mut c, mut n) = pair();
    let (id, f) = c.request("info", m(vec![])).unwrap();
    n.read(&f);
    let part = m(vec![(1, V::Uint(1)), (2, V::Uint(2))]);
    let chunk = m(vec![(1, V::Uint(id)), (3, V::Bytes(vec![0xa0])), (4, V::Uint(0)), (6, part)]);
    assert!(matches!(feed(&mut c, &n.send(&chunk)), Err(Error::Envelope(_))));
    assert!(c.is_closed());
}

#[test]
fn error_response_is_an_outcome_not_a_failure() {
    let (mut c, mut n) = pair();
    let (id, f) = c.request("claim/finish", m(vec![])).unwrap();
    n.read(&f);
    let e = m(vec![(1, V::Uint(id)), (4, V::Uint(9)), (5, m(vec![]))]);
    assert_eq!(feed(&mut c, &n.send(&e)), Ok(Some(Outcome::Err { code: 9, detail: m(vec![]) })));
    assert!(!c.is_closed());
    // the next request gets the next id
    assert_eq!(c.request("info", m(vec![])).unwrap().0, id + 1);
}
