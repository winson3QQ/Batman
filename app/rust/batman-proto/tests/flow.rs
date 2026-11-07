//! flow: every row of design §5.1 / §5.2 / §5.4 with a fake node reply (design §5.4: "每一列都有 Rust 假回應測項").

use batman_proto::cbor::Value as V;
use batman_proto::envelope::Outcome;
use batman_proto::flow::*;

fn m(pairs: Vec<(u64, V)>) -> V {
    V::Map(pairs.into_iter().map(|(k, v)| (V::Uint(k), v)).collect())
}
fn err(code: u64) -> Outcome {
    Outcome::Err { code, detail: m(vec![]) }
}
fn creds_body() -> V {
    m(vec![(1, V::Bytes(vec![1; 32])), (2, V::Bytes(vec![2; 32])), (3, V::Text("pw-xyz".into()))])
}
fn want_creds() -> Creds {
    Creds { owner_tag_key: [1; 32], adv_owner_key: [2; 32], root_password: "pw-xyz".into() }
}

#[test]
fn claim_finish_rows() {
    assert_eq!(claim_finish(&Outcome::Ok(creds_body())), ClaimFinish::Claimed(want_creds()));
    // a success the app cannot use is still committed on the node: replay, never "nothing happened"
    for bad in [
        m(vec![]),
        m(vec![(1, V::Bytes(vec![1; 31])), (2, V::Bytes(vec![2; 32])), (3, V::Text("p".into()))]),
        m(vec![(1, V::Bytes(vec![1; 32])), (2, V::Bytes(vec![2; 32])), (3, V::Text(String::new()))]),
        m(vec![(1, V::Bytes(vec![1; 32])), (2, V::Bytes(vec![2; 32])), (3, V::Bytes(b"p".to_vec()))]),
    ] {
        assert_eq!(claim_finish(&Outcome::Ok(bad)), ClaimFinish::Committed);
    }
    assert_eq!(claim_finish(&err(13)), ClaimFinish::Committed);
    let legacy = Outcome::Err { code: 6, detail: m(vec![(1, V::Text("claim".into())), (2, V::Uint(10))]) };
    assert_eq!(claim_finish(&legacy), ClaimFinish::LegacyNoSshKey);
    // 6 without reason 10, or for another capability: result unknown
    assert_eq!(claim_finish(&Outcome::Err { code: 6, detail: m(vec![(1, V::Text("claim".into()))]) }), ClaimFinish::Unknown);
    assert_eq!(claim_finish(&Outcome::Err { code: 6, detail: m(vec![(1, V::Text("x".into())), (2, V::Uint(10))]) }), ClaimFinish::Unknown);
    assert_eq!(claim_finish(&err(3)), ClaimFinish::BeginAgain);
    assert_eq!(claim_finish(&err(4)), ClaimFinish::AppBug);
    assert_eq!(claim_finish(&err(9)), ClaimFinish::TryReplay);
    for c in [1, 2, 5, 7, 8, 10, 11, 12, 14, 99] {
        assert_eq!(claim_finish(&err(c)), ClaimFinish::Unknown, "code {c}");
    }
}

#[test]
fn claim_replay_rows() {
    assert_eq!(claim_replay(&Outcome::Ok(creds_body())), ClaimReplay::Recovered(want_creds()));
    assert_eq!(claim_replay(&Outcome::Ok(m(vec![]))), ClaimReplay::Unknown);
    assert_eq!(claim_replay(&err(13)), ClaimReplay::Reconnect);
    assert_eq!(claim_replay(&err(12)), ClaimReplay::RateLimited);
    assert_eq!(claim_replay(&err(3)), ClaimReplay::Refused);
    assert_eq!(claim_replay(&err(4)), ClaimReplay::Refused);
    for c in [1, 2, 5, 6, 7, 9, 10, 11, 99] {
        assert_eq!(claim_replay(&err(c)), ClaimReplay::Unknown, "code {c}");
    }
}

#[test]
fn network_join_rows() {
    assert_eq!(network_join(&Outcome::Ok(m(vec![(1, V::Uint(0))]))), JoinReply::Applied);
    assert_eq!(network_join(&err(4)), JoinReply::Rejected);
    assert_eq!(network_join(&err(3)), JoinReply::NewNonce);
    for c in [5, 6, 7, 10, 11, 12, 13, 99] {
        assert_eq!(network_join(&err(c)), JoinReply::ReadInfo, "code {c}");
    }
}

#[test]
fn join_state_table() {
    let ours = [7u8; 16];
    let info = |extra: Vec<(u64, V)>| {
        let mut p = vec![(1, V::Text("abc".into())), (7, V::Uint(1))];
        p.extend(extra);
        m(p)
    };
    let id = |b: u8| V::Bytes(vec![b; 16]);
    assert_eq!(join_state(&info(vec![(9, V::Uint(1)), (10, id(7)), (11, V::Bool(false))]), &ours), JoinState::Applied { save_pending: false });
    assert_eq!(join_state(&info(vec![(9, V::Uint(1)), (10, id(7)), (11, V::Bool(true))]), &ours), JoinState::Applied { save_pending: true });
    assert_eq!(join_state(&info(vec![(10, id(7))]), &ours), JoinState::Applied { save_pending: false });
    assert_eq!(join_state(&info(vec![(11, V::Bool(true))]), &ours), JoinState::InProgress);
    assert_eq!(join_state(&info(vec![(11, V::Bool(false))]), &ours), JoinState::NotApplied);
    assert_eq!(join_state(&info(vec![(9, V::Uint(1)), (10, id(8)), (11, V::Bool(false))]), &ours), JoinState::OtherNetwork);
    assert_eq!(join_state(&info(vec![(10, id(8)), (11, V::Bool(true))]), &ours), JoinState::OtherNetwork);
    assert_eq!(join_state(&info(vec![]), &ours), JoinState::Unknown);
    // malformed: never Applied / NotApplied (NotApplied would re-send)
    assert_eq!(join_state(&info(vec![(10, V::Bytes(vec![7; 15]))]), &ours), JoinState::Unknown);
    assert_eq!(join_state(&info(vec![(10, V::Text("x".into()))]), &ours), JoinState::Unknown);
    assert_eq!(join_state(&info(vec![(11, V::Uint(0))]), &ours), JoinState::Unknown);
    assert_eq!(join_state(&info(vec![(10, id(7)), (11, V::Uint(1))]), &ours), JoinState::Unknown);
}
