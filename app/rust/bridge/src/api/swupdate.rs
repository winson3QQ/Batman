//! Software update for Dart (docs/design/254-app-update.md v0.4 §11): the sans-IO flow (batman_proto::swupd) behind
//! one opaque `SwUpdate` that the node page keeps for the whole update (re-logins included: a new owner session sends
//! its requests, `OwnerSession::request_sw` / `sw_answer`). Dart moves: BLE requests through the owner session, waits,
//! the PUT through Kotlin (channel dev.batman/swupdate, §11.1), button presses.
//! D8: the AP passphrase comes out only through `ap_credentials` (only when the Specifier is needed); the bearer only in
//! an Upload action (for Kotlin `upload`). No text here ever carries either; nothing is logged.

use batman_proto::cbor::Value;
use batman_proto::nodecert;
use batman_proto::swupd::{self as su, Action, Button, Flow, Picked, Put, Verb};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwKind {
    /// a BLE request: `OwnerSession::request_sw(sw)`, wait at most `wait_ms`; answer -> `sw_answer`, none -> `lost`,
    /// no session -> `no_link`. `note` = what the screen says meanwhile
    Send,
    /// wait `wait_ms`, then `resume` (`note`, `percent` meanwhile)
    Wait,
    /// the PUT (§11.1 order): `findNodeNetwork(ip)` / `joinAp` / `upload`; `keepalive` every 10 s meanwhile;
    /// the result -> `uploaded`
    Upload,
    /// a screen with `buttons`; a press -> `press` (Pick: the picker, then `picked`)
    Show,
    /// over: the screen without buttons
    Done,
    /// nothing to do (a late or a keepalive answer, a press that does not apply now)
    Nothing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwButton {
    Pick,
    Start,
    Cancel,
    Apply,
    ApplyAnyway,
    Abandon,
    SetAp,
    ApDone,
    Retry,
    WifiPanel,
    Refresh,
}

/// Kotlin `upload` / `joinAp` results (§11.1)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwPut {
    Ok200,
    Other,
    NoNetwork,
    Denied,
    /// v0.4.2: Kotlin `vpnActive` said a VPN covers the app (nothing was sent)
    Vpn,
}

/// one picked file as Kotlin `pickUpdateFiles` read it (§11.1)
pub struct SwFile {
    pub size: i64,
    pub head: Vec<u8>,
    pub data: Vec<u8>,
}

pub struct SwAction {
    pub kind: SwKind,
    pub wait_ms: u64,
    pub note: String,
    pub text: String,
    /// 「技術資訊」(codes; a dev build's trust line)
    pub tech: String,
    /// -1 = none
    pub percent: i32,
    pub buttons: Vec<SwButton>,
    /// Upload only
    pub ip: String,
    pub port: u16,
    /// Upload only: X-Batman-Upload (a secret: only for Kotlin `upload`)
    pub bearer_hex: String,
    pub size: u64,
    /// Upload only: the index of the payload in the picked list
    pub payload: u32,
    /// D5: the upload stage is on (false -> Dart calls `cancelUpload` once to release the Specifier network)
    pub uploading: bool,
}

impl SwAction {
    fn new(kind: SwKind) -> SwAction {
        SwAction {
            kind,
            wait_ms: 0,
            note: String::new(),
            text: String::new(),
            tech: String::new(),
            percent: -1,
            buttons: vec![],
            ip: String::new(),
            port: 0,
            bearer_hex: String::new(),
            size: 0,
            payload: 0,
            uploading: false,
        }
    }
}

fn button_in(b: SwButton) -> Button {
    match b {
        SwButton::Pick => Button::Pick,
        SwButton::Start => Button::Start,
        SwButton::Cancel => Button::Cancel,
        SwButton::Apply => Button::Apply,
        SwButton::ApplyAnyway => Button::ApplyAnyway,
        SwButton::Abandon => Button::Abandon,
        SwButton::SetAp => Button::SetAp,
        SwButton::ApDone => Button::ApDone,
        SwButton::Retry => Button::Retry,
        SwButton::WifiPanel => Button::WifiPanel,
        SwButton::Refresh => Button::Refresh,
    }
}

fn button_out(b: Button) -> SwButton {
    match b {
        Button::Pick => SwButton::Pick,
        Button::Start => SwButton::Start,
        Button::Cancel => SwButton::Cancel,
        Button::Apply => SwButton::Apply,
        Button::ApplyAnyway => SwButton::ApplyAnyway,
        Button::Abandon => SwButton::Abandon,
        Button::SetAp => SwButton::SetAp,
        Button::ApDone => SwButton::ApDone,
        Button::Retry => SwButton::Retry,
        Button::WifiPanel => SwButton::WifiPanel,
        Button::Refresh => SwButton::Refresh,
    }
}

/// One software update of one node, in memory only (D7).
#[flutter_rust_bridge::frb(opaque)]
pub struct SwUpdate {
    pub(crate) flow: Flow,
    /// the request of the last Send, for the owner session to send
    pub(crate) next: Option<(Verb, Value)>,
}

impl SwUpdate {
    /// D13: the trust gate of this build (dev / dev2: test trust shown; field: the production key only)
    #[flutter_rust_bridge::frb(sync)]
    pub fn new() -> SwUpdate {
        SwUpdate { flow: Flow::new(nodecert::DEV_TRUST), next: None }
    }

    /// tests: a flow with the given trust gate (the app always takes the build's, `new`)
    #[cfg(test)]
    pub(crate) fn with_trust(dev: bool) -> SwUpdate {
        SwUpdate { flow: Flow::new(dev), next: None }
    }

    pub(crate) fn act(&mut self, a: Option<Action>) -> SwAction {
        let mut out = match a {
            None => SwAction::new(SwKind::Nothing),
            Some(Action::Send { verb, body, wait_ms, note }) => {
                self.next = Some((verb, body));
                SwAction { wait_ms, note, ..SwAction::new(SwKind::Send) }
            }
            Some(Action::Wait { ms, note, percent }) => {
                SwAction { wait_ms: ms, note, percent: percent.map(|p| p as i32).unwrap_or(-1), ..SwAction::new(SwKind::Wait) }
            }
            Some(Action::Upload { ip, port, bearer, size, payload }) => SwAction {
                ip,
                port,
                bearer_hex: nodecert::hex_lower(&bearer),
                size,
                payload: payload as u32,
                note: su::T_UPLOADING.into(),
                ..SwAction::new(SwKind::Upload)
            },
            Some(Action::Show(s)) => SwAction {
                text: s.text,
                tech: s.tech,
                percent: s.percent.map(|p| p as i32).unwrap_or(-1),
                buttons: s.buttons.into_iter().map(button_out).collect(),
                ..SwAction::new(SwKind::Show)
            },
            Some(Action::Done(s)) => SwAction { text: s.text, tech: s.tech, ..SwAction::new(SwKind::Done) },
        };
        out.uploading = self.flow.uploading();
        out
    }

    /// §3.1: the entry reads (also 「重新整理」)
    #[flutter_rust_bridge::frb(sync)]
    pub fn start(&mut self) -> SwAction {
        let a = self.flow.start();
        self.act(Some(a))
    }

    /// U1: the files Kotlin `pickUpdateFiles` returned
    #[flutter_rust_bridge::frb(sync)]
    pub fn picked(&mut self, files: Vec<SwFile>) -> SwAction {
        let f: Vec<Picked> = files.into_iter().map(|x| Picked { size: x.size, head: x.head, data: x.data }).collect();
        let a = self.flow.picked(&f);
        self.act(a)
    }

    /// `now_ms`: Dart's monotonic clock (a Stopwatch), the same one for every call of this update
    #[flutter_rust_bridge::frb(sync)]
    pub fn press(&mut self, button: SwButton, now_ms: u64) -> SwAction {
        let a = self.flow.press(button_in(button), now_ms);
        self.act(a)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn resume(&mut self) -> SwAction {
        let a = self.flow.resume();
        self.act(a)
    }

    /// U6: every 10 s during the upload (a Send, or Nothing)
    #[flutter_rust_bridge::frb(sync)]
    pub fn keepalive(&mut self) -> SwAction {
        let a = self.flow.keepalive();
        self.act(a)
    }

    /// the Kotlin `upload` result (or `joinAp`'s denied / no_network)
    #[flutter_rust_bridge::frb(sync)]
    pub fn uploaded(&mut self, result: SwPut) -> SwAction {
        let r = match result {
            SwPut::Ok200 => Put::Ok200,
            SwPut::Other => Put::Other,
            SwPut::NoNetwork => Put::NoNetwork,
            SwPut::Denied => Put::Denied,
            SwPut::Vpn => Put::Vpn,
        };
        let a = self.flow.uploaded(r);
        self.act(a)
    }

    /// the request got no answer (timeout / link lost / not sent)
    #[flutter_rust_bridge::frb(sync)]
    pub fn lost(&mut self, now_ms: u64) -> SwAction {
        self.next = None;
        let a = self.flow.lost(now_ms);
        self.act(a)
    }

    /// no owner session could be opened
    #[flutter_rust_bridge::frb(sync)]
    pub fn no_link(&mut self, now_ms: u64) -> SwAction {
        self.next = None;
        let a = self.flow.no_link(now_ms);
        self.act(a)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn uploading(&self) -> bool {
        self.flow.uploading()
    }

    /// D5 / D8: [ssid, passphrase] for Kotlin `joinAp` only ([] when no window is open). Never shown or logged.
    #[flutter_rust_bridge::frb(sync)]
    pub fn ap_credentials(&self) -> Vec<String> {
        self.flow.ap_credentials().map(|(s, p)| vec![s, p]).unwrap_or_default()
    }
}

impl Default for SwUpdate {
    fn default() -> Self {
        Self::new()
    }
}

/// D5: what is said before the phone leaves its Wi-Fi for the node's AP
#[flutter_rust_bridge::frb(sync)]
pub fn sw_specifier_text() -> String {
    su::T_SPECIFIER.into()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// D13: the build's trust gate — a field build (no dev-trust) refuses a test-trust node before update/status
    #[test]
    fn new_takes_the_build_trust_gate() {
        let mut sw = SwUpdate::new();
        assert_eq!(sw.start().kind, SwKind::Send);
        let k15 = Value::Map(vec![(Value::Text("trust".into()), Value::Text("0123456789abcdef".into()))]);
        let st = Value::Map(vec![(Value::Uint(1), Value::Uint(2)), (Value::Uint(15), k15)]);
        let a = sw.flow.on_reply(su::Reply::Ok(st), 1);
        let a = sw.act(a);
        assert_eq!(a.kind, SwKind::Send, "info next");
        let a = sw.flow.on_reply(su::Reply::Ok(Value::Map(vec![])), 2);
        let a = sw.act(a);
        if nodecert::DEV_TRUST {
            assert_eq!(a.kind, SwKind::Send, "dev: update/status next");
        } else {
            assert_eq!((a.kind, a.text.as_str(), a.buttons.clone()), (SwKind::Show, su::T_TRUST_FIELD, vec![SwButton::Refresh]));
        }
    }
}
