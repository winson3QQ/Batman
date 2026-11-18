//! #329 PR 6 D7 / D7a, tests only (shared by batman-proto's tests/say_scan.rs and the bridge's src/lib.rs through
//! `#[path]`): the technical part of a sentence is wrapped in U+001E … U+001F.
//! - `split_code`: the same rule as Dart's `splitCode` (app/lib/say.dart), checked against the shared vectors in
//!   app/test/fixtures/split_vectors.txt;
//! - `literals` / `violations`: a small Rust string-literal scanner and the D7a (1) rule;
//! - `main_ascii_words`: the D7a (2) check that the main part has no ASCII word outside the whitelist.
#![allow(dead_code)]

pub const OPEN: char = '\u{1E}';
pub const CLOSE: char = '\u{1F}';

/// (main, tech): main = the line without every paired OPEN … CLOSE segment; tech = those segments in order, joined
/// with 「；」 (empty ones skipped). Unpaired (a lone CLOSE, an OPEN never closed, or an OPEN inside an open segment)
/// -> both control characters removed and the whole line is main (rather show too much than swallow words).
pub fn split_code(line: &str) -> (String, String) {
    let mut main = String::new();
    let mut segs: Vec<String> = vec![];
    let mut cur: Option<String> = None;
    for ch in line.chars() {
        match (ch, cur.as_mut()) {
            (OPEN, None) => cur = Some(String::new()),
            (OPEN, Some(_)) | (CLOSE, None) => return (line.chars().filter(|c| *c != OPEN && *c != CLOSE).collect(), String::new()),
            (CLOSE, Some(_)) => segs.push(cur.take().unwrap()),
            (c, Some(s)) => s.push(c),
            (c, None) => main.push(c),
        }
    }
    if cur.is_some() {
        return (line.chars().filter(|c| *c != OPEN && *c != CLOSE).collect(), String::new());
    }
    (main, segs.into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("；"))
}

/// The shared vectors: `input|main|tech`, `<<` = U+001E, `>>` = U+001F, `#` comments. Read from the app's test tree.
pub fn split_vectors() -> Vec<(String, String, String)> {
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../../test/fixtures/split_vectors.txt");
    let text = std::fs::read_to_string(p).unwrap_or_else(|e| panic!("{p}: {e}"));
    let dec = |s: &str| s.replace("<<", "\u{1E}").replace(">>", "\u{1F}");
    let v: Vec<_> = text
        .lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
        .map(|l| {
            let f: Vec<&str> = l.split('|').collect();
            assert_eq!(f.len(), 3, "bad vector line: {l}");
            (dec(f[0]), dec(f[1]), dec(f[2]))
        })
        .collect();
    assert!(v.len() >= 10, "{p}: only {} vectors", v.len());
    v
}

/// Every string literal of a Rust source (plain, raw, byte), decoded, with its 1-based start line. Comments, char
/// literals and lifetimes are skipped.
pub fn literals(src: &str) -> Vec<(usize, String)> {
    let c: Vec<char> = src.chars().collect();
    let (mut i, mut line, mut out) = (0usize, 1usize, vec![]);
    let nl = |s: &[char]| s.iter().filter(|x| **x == '\n').count();
    while i < c.len() {
        let ch = c[i];
        if ch == '/' && c.get(i + 1) == Some(&'/') {
            while i < c.len() && c[i] != '\n' {
                i += 1;
            }
        } else if ch == '/' && c.get(i + 1) == Some(&'*') {
            let (mut depth, st) = (0usize, i);
            while i < c.len() {
                if c[i] == '/' && c.get(i + 1) == Some(&'*') {
                    depth += 1;
                    i += 2;
                } else if c[i] == '*' && c.get(i + 1) == Some(&'/') {
                    depth -= 1;
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    i += 1;
                }
            }
            line += nl(&c[st..i.min(c.len())]);
        } else if ch == '\'' {
            // a char literal ('x', '\n', '\u{1E}', '\'') or a lifetime ('a)
            if c.get(i + 1) == Some(&'\\') {
                let mut j = i + 2;
                while j < c.len() && c[j] != '\'' {
                    j += 1;
                }
                i = j + 1;
            } else if c.get(i + 2) == Some(&'\'') {
                i += 3;
            } else {
                i += 1;
            }
        } else if (ch == 'r' || (ch == 'b' && c.get(i + 1) == Some(&'r')))
            && !prev_ident(&c, i)
            && {
                let k = if ch == 'b' { i + 2 } else { i + 1 };
                let mut h = k;
                while c.get(h) == Some(&'#') {
                    h += 1;
                }
                c.get(h) == Some(&'"')
            }
        {
            let mut k = if ch == 'b' { i + 2 } else { i + 1 };
            let mut hashes = 0;
            while c[k] == '#' {
                hashes += 1;
                k += 1;
            }
            k += 1; // the quote
            let st = k;
            loop {
                if k >= c.len() {
                    break;
                }
                if c[k] == '"' && (0..hashes).all(|h| c.get(k + 1 + h) == Some(&'#')) {
                    break;
                }
                k += 1;
            }
            let body: String = c[st..k.min(c.len())].iter().collect();
            out.push((line, body));
            line += nl(&c[i..k.min(c.len())]);
            i = k + 1 + hashes;
        } else if ch == '"' {
            let st = i;
            let mut k = i + 1;
            let mut s = String::new();
            while k < c.len() && c[k] != '"' {
                if c[k] == '\\' {
                    let e = c.get(k + 1).copied().unwrap_or(' ');
                    match e {
                        'n' => s.push('\n'),
                        't' => s.push('\t'),
                        'r' => s.push('\r'),
                        '0' => s.push('\0'),
                        '\\' => s.push('\\'),
                        '"' => s.push('"'),
                        '\'' => s.push('\''),
                        'x' => {
                            let h: String = c[k + 2..k + 4].iter().collect();
                            s.push(u8::from_str_radix(&h, 16).map(char::from).unwrap_or('?'));
                            k += 2;
                        }
                        'u' => {
                            let mut j = k + 3; // past `u{`
                            let mut h = String::new();
                            while c[j] != '}' {
                                h.push(c[j]);
                                j += 1;
                            }
                            s.push(u32::from_str_radix(&h, 16).ok().and_then(char::from_u32).unwrap_or('?'));
                            k = j - 1;
                        }
                        '\n' => {
                            // a line continuation: the newline and the next line's leading white space
                            let mut j = k + 2;
                            while j < c.len() && c[j].is_whitespace() {
                                j += 1;
                            }
                            k = j - 2;
                        }
                        _ => s.push(e),
                    }
                    k += 2;
                } else {
                    s.push(c[k]);
                    k += 1;
                }
            }
            out.push((line, s));
            line += nl(&c[st..k.min(c.len())]);
            i = k + 1;
        } else {
            if ch == '\n' {
                line += 1;
            }
            i += 1;
        }
    }
    out
}

fn prev_ident(c: &[char], i: usize) -> bool {
    i > 0 && (c[i - 1].is_alphanumeric() || c[i - 1] == '_')
}

/// The part of one literal that is NOT between OPEN and CLOSE (an OPEN not closed in the literal runs to its end).
pub fn outside(lit: &str) -> String {
    let mut out = String::new();
    let mut inside = false;
    for ch in lit.chars() {
        match ch {
            OPEN => inside = true,
            CLOSE => inside = false,
            c if !inside => out.push(c),
            _ => {}
        }
    }
    out
}

/// D7a (1): why this literal breaks the rule (None = fine): 代碼, 原因 + a digit or `{`, 回覆碼, or a `{…}`
/// interpolation inside full-width parentheses, anywhere outside the literal's OPEN … CLOSE segments.
pub fn violation(lit: &str) -> Option<&'static str> {
    let o = outside(lit);
    if o.contains("代碼") {
        return Some("代碼");
    }
    if o.contains("回覆碼") {
        return Some("回覆碼");
    }
    let ch: Vec<char> = o.chars().collect();
    for w in ch.windows(4) {
        if w[0] == '原' && w[1] == '因' && w[2] == ' ' && (w[3].is_ascii_digit() || w[3] == '{') {
            return Some("原因 N");
        }
    }
    // （ … {x} … ）: an interpolation inside full-width parentheses (`{{` is a literal brace)
    let mut depth = 0;
    let mut k = 0;
    while k < ch.len() {
        match ch[k] {
            '（' => depth += 1,
            '）' => depth = (depth - 1).max(0),
            '{' if ch.get(k + 1) == Some(&'{') => k += 1,
            '{' if depth > 0 => return Some("（{…}）"),
            _ => {}
        }
        k += 1;
    }
    None
}

/// One allow-list entry: in `file` (a path suffix), every literal that contains `has` is exempt; `why` = the category.
pub struct Allow {
    pub file: &'static str,
    pub has: &'static str,
    pub why: &'static str,
}

/// D7a (1) over every `.rs` file under `<crate>/src`: the literals that break the rule and are not allowed, plus the
/// allow-list entries that matched nothing (a stale entry is a FAIL too). Panics when no file was scanned.
pub fn violations(allow: &[Allow]) -> Vec<String> {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = vec![];
    walk(&root, &mut files);
    assert!(files.len() >= 5, "D7a scan: only {} source files under {}", files.len(), root.display());
    let mut used = vec![false; allow.len()];
    let mut bad = vec![];
    let mut seen = 0;
    for f in &files {
        let rel = f.strip_prefix(&root).unwrap().to_string_lossy().replace('\\', "/");
        if rel.ends_with("frb_generated.rs") {
            continue;
        }
        let src = std::fs::read_to_string(f).unwrap();
        for (line, lit) in literals(&src) {
            seen += 1;
            let Some(why) = violation(&lit) else { continue };
            match allow.iter().position(|a| rel.ends_with(a.file) && lit.contains(a.has)) {
                Some(p) => used[p] = true,
                None => bad.push(format!("{rel}:{line}: {why}: {lit:?}")),
            }
        }
    }
    assert!(seen > 100, "D7a scan: only {seen} literals");
    for (a, u) in allow.iter().zip(used) {
        if !u && files.iter().any(|f| f.to_string_lossy().replace('\\', "/").ends_with(a.file)) {
            bad.push(format!("stale allow-list entry: {} / {:?} ({})", a.file, a.has, a.why));
        }
    }
    bad
}

fn walk(d: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    for e in std::fs::read_dir(d).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            walk(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            out.push(p);
        }
    }
}

/// D7a (2): the ASCII words of `line`'s main part that are not on the whitelist (App, QR, Wi-Fi, SSH, HaLow, US, TW,
/// MHz, a version number, a 「…XXXX」 last-4, a fingerprint, the log markers at the start). Empty = fine.
pub fn main_ascii_words(line: &str) -> Vec<String> {
    let (main, _) = split_code(line);
    let mut m = main.as_str();
    // the leading log markers ("[REQ_FAIL] ", "[ANSWER] [NET_MADE] ")
    while let Some(r) = m.strip_prefix('[') {
        match r.find("] ") {
            Some(e) if r[..e].bytes().all(|b| b.is_ascii_uppercase() || b == b'_' || b.is_ascii_digit()) => m = &r[e + 2..],
            _ => break,
        }
    }
    const OK: [&str; 9] = ["App", "QR", "Wi-Fi", "SSH", "HaLow", "US", "TW", "MHz", "Mbit/s"];
    let mut bad = vec![];
    let ch: Vec<char> = m.chars().collect();
    let mut k = 0;
    while k < ch.len() {
        if ch[k].is_ascii_alphabetic() {
            let st = k;
            while k < ch.len() && (ch[k].is_ascii_alphanumeric() || ch[k] == '-' || ch[k] == '/' || ch[k] == '_') {
                k += 1;
            }
            let w: String = ch[st..k].iter().collect();
            let after_ellipsis = st > 0 && ch[st - 1] == '…';
            let version = w.starts_with('v') && w[1..].chars().all(|c| c.is_ascii_digit() || c == '.') && w.len() > 1;
            let hexish = w.len() >= 4 && w.chars().all(|c| c.is_ascii_hexdigit());
            if !(OK.contains(&w.as_str()) || after_ellipsis || version || hexish) {
                bad.push(w);
            }
        } else {
            k += 1;
        }
    }
    bad
}

/// D7a (2) for one sentence: the main part has no ASCII word outside the whitelist, and every `tech` piece is in the
/// technical part (not in the main part).
pub fn assert_split(line: &str, tech: &[&str]) {
    let (main, t) = split_code(line);
    let bad = main_ascii_words(line);
    assert!(bad.is_empty(), "ASCII words {bad:?} in the main part of {line:?}");
    assert!(!main.contains("代碼") && !main.contains("回覆碼"), "a code in the main part of {line:?}");
    for p in tech.iter().map(|p| p.replace([OPEN, CLOSE], "")) {
        let p = p.as_str();
        assert!(t.contains(p), "{p:?} not in the technical part {t:?} of {line:?}");
        assert!(!main.contains(p), "{p:?} in the main part {main:?} of {line:?}");
    }
}
