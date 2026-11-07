//! Batman provisioning protocol core for the phone app — sans-IO (docs/design/254-app-s1.md v8.1, 219-protocol.md §10).
//!
//! No I/O and no long-term private keys live here: the caller feeds bytes in and gets bytes / signing requests out.
//! Modules are added in the order of the design's test plan (§8), each checked byte-for-byte against
//! `tests/vectors/219-protocol/vectors.json`.

pub mod cbor;
pub mod conn;
pub mod claim;
pub mod cose;
pub mod envelope;
pub mod flow;
pub mod sig;
pub mod frame;
pub mod kdf;
pub mod nodecert;
pub mod noise;
