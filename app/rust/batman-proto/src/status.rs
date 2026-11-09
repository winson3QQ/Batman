//! The STATUS characteristic (…4d5c…, read without a session): a public summary the node publishes before any
//! handshake (feed/batman-prov/src/provd/server.go:562-576; vectors `status_public`).
//!
//! `{1: [proto versions], 2: [transports], 3: state, 4: trial, 5?: last 4 of the device id}`; key 5 only when the state
//! is unclaimed (0) or legacy (3). Strict: an unknown key, a wrong type, key 5 in another state or a device id longer
//! than 4 characters is refused (the vectors' `bad_*` cases) — the app picks a node by key 5 (design §5.1 step 1), so a
//! value it does not understand is not guessed at. A stale cache is an ATT error 0x0E on the node side (no value at
//! all), which the BLE layer reports; it never reaches this parser.

use crate::cbor::{self, Value};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum State {
    Unclaimed,
    Claimed,
    Member,
    Legacy,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub versions: Vec<u64>,
    pub transports: Vec<String>,
    pub state: State,
    pub trial: bool,
    /// The last 4 characters of the device id (unclaimed / legacy only).
    pub id_last4: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Cbor(cbor::Error),
    NotAMap,
    UnknownKey(String),
    Missing(u64),
    Type(u64),
    State(u64),
    TailNotAllowed,
    Tail,
}

pub fn decode(buf: &[u8]) -> Result<Status, Error> {
    let v = cbor::decode(buf).map_err(Error::Cbor)?;
    let Value::Map(m) = &v else { return Err(Error::NotAMap) };
    for (k, _) in m {
        match k {
            Value::Uint(1..=5) => {}
            other => return Err(Error::UnknownKey(format!("{other:?}"))),
        }
    }
    let get = |k: u64| v.get(k).ok_or(Error::Missing(k));
    let versions = match get(1)? {
        Value::Array(a) => a.iter().map(|x| x.as_uint().ok_or(Error::Type(1))).collect::<Result<Vec<_>, _>>()?,
        _ => return Err(Error::Type(1)),
    };
    let transports = match get(2)? {
        Value::Array(a) => a.iter().map(|x| x.as_text().map(str::to_string).ok_or(Error::Type(2))).collect::<Result<Vec<_>, _>>()?,
        _ => return Err(Error::Type(2)),
    };
    let state = match get(3)?.as_uint().ok_or(Error::Type(3))? {
        0 => State::Unclaimed,
        1 => State::Claimed,
        2 => State::Member,
        3 => State::Legacy,
        n => return Err(Error::State(n)),
    };
    let trial = match get(4)? {
        Value::Bool(b) => *b,
        _ => return Err(Error::Type(4)),
    };
    let id_last4 = match v.get(5) {
        None => None,
        Some(t) => {
            if !matches!(state, State::Unclaimed | State::Legacy) {
                return Err(Error::TailNotAllowed);
            }
            let s = t.as_text().ok_or(Error::Type(5))?;
            if s.len() != 4 || !s.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()) {
                return Err(Error::Tail);
            }
            Some(s.to_string())
        }
    };
    Ok(Status { versions, transports, state, trial, id_last4 })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(h: &str) -> Result<Status, Error> {
        decode(&hex::decode(h).unwrap())
    }

    // the four `status_public` vectors (tests/vectors/219-protocol/vectors.json), verbatim
    #[test]
    fn vectors() {
        let s = d("a50182010002826568616c6f7763677073030004f4056434646565").unwrap();
        assert_eq!(s.state, State::Unclaimed);
        assert_eq!(s.versions, vec![1, 0]);
        assert_eq!(s.transports, vec!["halow".to_string(), "gps".to_string()]);
        assert!(!s.trial);
        assert_eq!(s.id_last4.as_deref(), Some("4dee"));
        let s = d("a40182010002826568616c6f7763677073030204f5").unwrap();
        assert_eq!(s.state, State::Member);
        assert!(s.trial);
        assert_eq!(s.id_last4, None);
        assert_eq!(d("a50182010002816568616c6f77030204f4056434646565"), Err(Error::TailNotAllowed));
        assert!(matches!(d("a50182010002816568616c6f77030204f40672303132336135663063336531623734646565"), Err(Error::UnknownKey(_))));
    }

    // what the node's encoder writes today (server.go:571: transports ["halow"] only)
    #[test]
    fn node_encoder_shape() {
        let m = Value::Map(vec![
            (Value::Uint(1), Value::Array(vec![Value::Uint(1), Value::Uint(0)])),
            (Value::Uint(2), Value::Array(vec![Value::Text("halow".into())])),
            (Value::Uint(3), Value::Uint(3)),
            (Value::Uint(4), Value::Bool(false)),
            (Value::Uint(5), Value::Text("0cfd".into())),
        ]);
        let s = decode(&cbor::encode(&m)).unwrap();
        assert_eq!(s.state, State::Legacy);
        assert_eq!(s.id_last4.as_deref(), Some("0cfd"));
    }

    #[test]
    fn refused() {
        let base = |k5: Value, st: u64| {
            cbor::encode(&Value::Map(vec![
                (Value::Uint(1), Value::Array(vec![Value::Uint(1), Value::Uint(0)])),
                (Value::Uint(2), Value::Array(vec![Value::Text("halow".into())])),
                (Value::Uint(3), Value::Uint(st)),
                (Value::Uint(4), Value::Bool(false)),
                (Value::Uint(5), k5),
            ]))
        };
        assert_eq!(decode(&base(Value::Text("4DEE".into()), 0)), Err(Error::Tail));
        assert_eq!(decode(&base(Value::Text("4de".into()), 0)), Err(Error::Tail));
        assert_eq!(decode(&base(Value::Text("4dee".into()), 4)), Err(Error::State(4)));
        assert_eq!(decode(&base(Value::Bytes(vec![1, 2]), 0)), Err(Error::Type(5)));
        assert_eq!(decode(&base(Value::Text("4dee".into()), 1)), Err(Error::TailNotAllowed));
        assert_eq!(decode(&[0x80]), Err(Error::NotAMap));
        assert!(matches!(decode(&[0xa1, 0x01]), Err(Error::Cbor(_))));
        let no4 = cbor::encode(&Value::Map(vec![
            (Value::Uint(1), Value::Array(vec![])),
            (Value::Uint(2), Value::Array(vec![])),
            (Value::Uint(3), Value::Uint(2)),
        ]));
        assert_eq!(decode(&no4), Err(Error::Missing(4)));
    }
}

/// The `status` answer of an owner / member session (CDDL status-resp; node 254-p3-impl §3.4), as one display line:
/// {1: node-state, ?2: verdict 0 ok / 1 degraded / 2 down, ?3: neighbours, ?4: p5_saved, ?5: {1: reason, 2: text},
/// ?15: {node, image, uptime_s, temp_c, ...}}. Key 1 is required; the rest is shown when present.
// Display text is plain Traditional Chinese for a non-technical user (#254 app); node-supplied values and codes are kept
// verbatim, codes in parentheses for support.
pub fn decode_owner(v: &Value) -> Result<String, String> {
    let st = match v.get(1).and_then(Value::as_uint) {
        Some(0) => "未認領",
        Some(1) => "已認領（還沒加入網路）",
        Some(2) => "已加入網路",
        Some(3) => "舊版節點",
        _ => return Err("缺少節點狀態（欄位 1）".into()),
    };
    let mut out = vec![format!("狀態：{st}")];
    if let Some(vd) = v.get(2).and_then(Value::as_uint) {
        out.push(match vd { 0 => "網路狀況正常".into(), 1 => "網路狀況不穩".into(), 2 => "網路中斷".into(), n => format!("網路狀況代碼 {n}") });
    }
    if let Some(n) = v.get(3).and_then(Value::as_uint) {
        out.push(format!("連到 {n} 台鄰近節點"));
    }
    match v.get(4) {
        Some(Value::Bool(true)) => out.push("設定已存檔".into()),
        Some(Value::Bool(false)) => out.push("設定「尚未」存檔".into()),
        _ => {}
    }
    if let Some(j) = v.get(5) {
        let c = j.get(1).and_then(Value::as_uint).unwrap_or(0);
        let t = j.get(2).and_then(Value::as_text).unwrap_or("");
        out.push(format!("還沒連上網路（代碼 {c}：{t}）"));
    }
    if let Some(f) = v.get(15) {
        if let Value::Map(m) = f {
            for (k, x) in m {
                if let (Value::Text(k), Value::Text(x)) = (k, x) {
                    let line = match k.as_str() {
                        "node" => Some(format!("裝置名稱 {x}")),
                        "image" => Some(format!("軟體版本 {x}")),
                        "temp_c" => Some(format!("溫度 {x}°C")),
                        "tenants" => Some(format!("附加服務 {x}")),
                        _ => None,
                    };
                    if let (Some(l), false) = (line, x.is_empty()) {
                        out.push(l);
                    }
                }
                if let (Value::Text(k), Value::Uint(x)) = (k, x) {
                    if k == "uptime_s" {
                        out.push(format!("已開機 {}", duration_zh(*x)));
                    }
                }
                if let (Value::Text(k), Value::Bool(true)) = (k, x) {
                    if k == "stale" {
                        out.push("節點的狀態資料還沒準備好".into());
                    }
                }
            }
        }
    }
    Ok(out.join("，"))
}

/// Seconds as a short Chinese duration: "42 秒", "6 分 42 秒", "3 小時 5 分", "2 天 4 小時".
pub fn duration_zh(s: u64) -> String {
    match s {
        0..=59 => format!("{s} 秒"),
        60..=3599 => format!("{} 分 {} 秒", s / 60, s % 60),
        3600..=86399 => format!("{} 小時 {} 分", s / 3600, s % 3600 / 60),
        _ => format!("{} 天 {} 小時", s / 86400, s % 86400 / 3600),
    }
}

#[cfg(test)]
mod owner_tests {
    use super::*;

    #[test]
    fn decode_owner_status() {
        let v = Value::Map(vec![
            (Value::Uint(1), Value::Uint(2)),
            (Value::Uint(2), Value::Uint(2)),
            (Value::Uint(3), Value::Uint(1)),
            (Value::Uint(4), Value::Bool(true)),
            (Value::Uint(15), Value::Map(vec![(Value::Text("node".into()), Value::Text("BCM2711-6c89".into())), (Value::Text("uptime_s".into()), Value::Uint(402))])),
        ]);
        assert_eq!(decode_owner(&v).unwrap(), "狀態：已加入網路，網路中斷，連到 1 台鄰近節點，設定已存檔，裝置名稱 BCM2711-6c89，已開機 6 分 42 秒");
        let nj = Value::Map(vec![
            (Value::Uint(1), Value::Uint(1)),
            (Value::Uint(5), Value::Map(vec![(Value::Uint(1), Value::Uint(7)), (Value::Uint(2), Value::Text("SEARCHING".into()))])),
        ]);
        assert_eq!(decode_owner(&nj).unwrap(), "狀態：已認領（還沒加入網路），還沒連上網路（代碼 7：SEARCHING）");
        assert_eq!(decode_owner(&Value::Map(vec![])), Err("缺少節點狀態（欄位 1）".to_string()));
        let stale = Value::Map(vec![(Value::Uint(1), Value::Uint(1)), (Value::Uint(15), Value::Map(vec![(Value::Text("stale".into()), Value::Bool(true))]))]);
        assert_eq!(decode_owner(&stale).unwrap(), "狀態：已認領（還沒加入網路），節點的狀態資料還沒準備好");
        let rest = Value::Map(vec![
            (Value::Uint(1), Value::Uint(0)),
            (Value::Uint(2), Value::Uint(1)),
            (Value::Uint(4), Value::Bool(false)),
            (Value::Uint(15), Value::Map(vec![(Value::Text("image".into()), Value::Text("1.8.0".into())), (Value::Text("temp_c".into()), Value::Text("48".into()))])),
        ]);
        assert_eq!(decode_owner(&rest).unwrap(), "狀態：未認領，網路狀況不穩，設定「尚未」存檔，軟體版本 1.8.0，溫度 48°C");
    }

    #[test]
    fn durations() {
        assert_eq!(duration_zh(0), "0 秒");
        assert_eq!(duration_zh(59), "59 秒");
        assert_eq!(duration_zh(402), "6 分 42 秒");
        assert_eq!(duration_zh(3600 * 3 + 5 * 60 + 9), "3 小時 5 分");
        assert_eq!(duration_zh(86400 * 2 + 3600 * 4 + 1), "2 天 4 小時");
    }
}
