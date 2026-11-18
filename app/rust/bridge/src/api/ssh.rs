//! #329 PR 6 D2: the 「SSH 金鑰」 page's checks of one line (developer options). The node's own rule
//! (feed/batman-prov/src/node/node.go:752, :848; 219-protocol.md:223): `^ssh-ed25519 [A-Za-z0-9+/=]{1,200}( [ -~]{0,40})?$`,
//! at most 256 bytes, no CR / LF. The app is stricter in one way: the key's base64 must decode (the fingerprint is
//! taken over the decoded blob), else the line is refused (fail-closed; plan §13).

use sha2::{Digest, Sha256};

const MAX_LINE: usize = 256;
const PREFIX: &str = "ssh-ed25519 ";

fn b64_value(c: u8) -> Option<u32> {
    Some(match c {
        b'A'..=b'Z' => c - b'A',
        b'a'..=b'z' => c - b'a' + 26,
        b'0'..=b'9' => c - b'0' + 52,
        b'+' => 62,
        b'/' => 63,
        _ => return None,
    } as u32)
}

/// Standard base64 with its `=` padding (as OpenSSH writes a public key); None on anything else.
fn b64_decode(s: &str) -> Option<Vec<u8>> {
    let b = s.as_bytes();
    if b.is_empty() || b.len() % 4 != 0 {
        return None;
    }
    let pad = b.iter().rev().take_while(|&&c| c == b'=').count();
    if pad > 2 || b[..b.len() - pad].contains(&b'=') {
        return None;
    }
    let mut out = Vec::with_capacity(b.len() / 4 * 3);
    for chunk in b.chunks(4) {
        let mut n = 0u32;
        let mut real = 0;
        for &c in chunk {
            n <<= 6;
            if c != b'=' {
                n |= b64_value(c)?;
                real += 1;
            }
        }
        let bytes = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        out.extend_from_slice(&bytes[..real - 1]);
    }
    Some(out)
}

/// Standard base64 without `=` (ssh-keygen's fingerprint form).
fn b64_encode_nopad(d: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::new();
    for c in d.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        for i in 0..=c.len() {
            s.push(A[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    s
}

/// The node's regex, by hand: the prefix, 1–200 of `[A-Za-z0-9+/=]`, then optionally one space and 0–40 printable
/// ASCII characters (space to `~`), and nothing else.
fn node_accepts(line: &str) -> bool {
    let Some(rest) = line.strip_prefix(PREFIX) else { return false };
    let key_len = rest.bytes().take_while(|c| c.is_ascii_alphanumeric() || matches!(c, b'+' | b'/' | b'=')).count();
    if key_len == 0 || key_len > 200 {
        return false;
    }
    let tail = &rest[key_len..];
    match tail.strip_prefix(' ') {
        None => tail.is_empty(),
        Some(c) => c.len() <= 40 && c.bytes().all(|b| (0x20..=0x7e).contains(&b)),
    }
}

/// Why the node (or this app) would not take [line], in words; None = it is taken. [line] is one line as the user
/// gave it, its trailing CR already removed by the page.
#[flutter_rust_bridge::frb(sync)]
pub fn ssh_line_problem(line: String) -> Option<String> {
    if line.len() > MAX_LINE {
        return Some(format!("超過 {MAX_LINE} 個位元組"));
    }
    if line.contains('\r') || line.contains('\n') {
        return Some("行中間有換行字元".into());
    }
    if !node_accepts(&line) {
        return Some("不是節點接受的格式：要是 ssh-ed25519 公鑰，後面的註解最多 40 個英數字元".into());
    }
    if ssh_fingerprint(line).is_none() {
        return Some("金鑰內容解不開".into());
    }
    None
}

/// The line's SHA256 fingerprint as ssh-keygen prints it (`SHA256:` + base64 of SHA-256 over the decoded key blob,
/// without `=`); None when the line is not one the node takes or its key does not decode.
#[flutter_rust_bridge::frb(sync)]
pub fn ssh_fingerprint(line: String) -> Option<String> {
    if line.len() > MAX_LINE || !node_accepts(&line) {
        return None;
    }
    let key = line[PREFIX.len()..].split(' ').next()?;
    let blob = b64_decode(key)?;
    Some(format!("SHA256:{}", b64_encode_nopad(&Sha256::digest(&blob))))
}

#[cfg(test)]
mod tests {
    use super::*;

    // ssh-keygen -t ed25519 / ssh-keygen -lf (OpenSSH, WSL Ubuntu 24.04, 2026-11-18): throwaway keys made for the test
    const K1: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAaL1R+1HSxy0in+JB+NmzAgWcGutvddS5VwtznDJFaC lab@test";
    const F1: &str = "SHA256:Eg+nWtOYtyqtCfRoM/7tO75hY9WROxklHyY+1YiCXCI";
    const K2: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkZLcMu9wTMEoJgzZvcq3AtMLy8j2y4bm6F/iW6Qz9Z ";
    const F2: &str = "SHA256:viFJWaOp4vg6jfumspq8LSMb0ChDfnBQjyhjnC7mHGU";

    /// T6-3: the fingerprint equals ssh-keygen's for the same line (with a comment, and with an empty one).
    #[test]
    fn t6_3_fingerprint_matches_ssh_keygen() {
        assert_eq!(ssh_fingerprint(K1.into()).as_deref(), Some(F1));
        assert_eq!(ssh_fingerprint(K2.into()).as_deref(), Some(F2));
        assert_eq!(ssh_fingerprint(K1.trim_end_matches(" lab@test").into()).as_deref(), Some(F1), "no comment");
        assert_eq!(ssh_line_problem(K1.into()), None);
        assert_eq!(ssh_line_problem(K2.into()), None);
    }

    /// T6-3: the node's rule, case by case (node.go:752, :848).
    #[test]
    fn t6_3_node_rule() {
        let key = &K1[PREFIX.len()..K1.len() - " lab@test".len()];
        let bad = [
            "ssh-rsa AAAAB3NzaC1yc2E x".to_string(),          // another key type
            format!("ssh-ed25519  {key}"),                     // two spaces
            format!("ssh-ed25519 {key} {}", "c".repeat(41)),  // comment > 40
            format!("ssh-ed25519 {key} 註解"),                  // comment not printable ASCII
            format!("ssh-ed25519 {key}\r"),                    // a CR left
            format!("ssh-ed25519 {key} a\nb"),                 // a line break inside
            format!("ssh-ed25519 {}", "A".repeat(201)),        // key > 200
            "ssh-ed25519 ".to_string(),                        // no key
            format!(" ssh-ed25519 {key}"),                     // leading space
        ];
        for b in &bad {
            assert!(ssh_line_problem(b.clone()).is_some(), "{b:?} must be refused");
            assert_eq!(ssh_fingerprint(b.clone()), None, "{b:?}");
        }
        assert_eq!(ssh_line_problem(format!("ssh-ed25519 {key} {}", "c".repeat(40))), None, "comment of 40 is fine");
        // > 256 bytes although every part is within its own limit is impossible (12 + 200 + 41 = 253): the byte cap
        // is checked first all the same
        assert_eq!(ssh_line_problem("x".repeat(257)).as_deref(), Some("超過 256 個位元組"));
    }

    /// The app is stricter than the node in one way: a key the regex takes but whose base64 does not decode.
    #[test]
    fn t6_3_undecodable_key_refused() {
        assert_eq!(ssh_line_problem("ssh-ed25519 AAAA= x".into()).as_deref(), Some("金鑰內容解不開"));
        assert_eq!(ssh_fingerprint("ssh-ed25519 A=AA x".into()), None);
    }
}
