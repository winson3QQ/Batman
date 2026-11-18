pub mod api;
mod frb_generated;
/// tests only: the fake claimed node of 254-app-replay §10, shared with batman-proto's tests (outside `api`, so the
/// codegen never sees it)
#[cfg(test)]
#[path = "../../batman-proto/tests/support/replay_node.rs"]
mod replay_node;
/// tests only (#329 PR 6 D7 / D7a): the shared split rule and string-literal scanner, and this crate's scan (both kept
/// outside src/, so the allow-list's own strings are not scanned)
#[cfg(test)]
#[path = "../../batman-proto/tests/support/say_scan.rs"]
pub(crate) mod say_scan;
#[cfg(test)]
#[path = "../test_support/say_scan.rs"]
mod say_scan_tests;
