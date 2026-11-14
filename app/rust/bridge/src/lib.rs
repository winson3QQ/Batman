pub mod api;
mod frb_generated;
/// tests only: the fake claimed node of 254-app-replay §10, shared with batman-proto's tests (outside `api`, so the
/// codegen never sees it)
#[cfg(test)]
#[path = "../../batman-proto/tests/support/replay_node.rs"]
mod replay_node;
