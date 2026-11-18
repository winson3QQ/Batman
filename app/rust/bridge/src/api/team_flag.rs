//! #329 PR 6 D5(a): whether this build works out the whole-team section (254-app-team-status §4.3: the N+1 switch).
//! The app's automatic read asks this before it opens a network record for the team view; false (version N) -> the
//! read does exactly what PR 5 did.

/// = `teamview::WRITE_MESH_ADDR` (false in every shippable build; the `team-write` feature is tests only).
#[flutter_rust_bridge::frb(sync)]
pub fn team_enabled() -> bool {
    batman_proto::teamview::WRITE_MESH_ADDR
}

#[cfg(test)]
mod tests {
    use super::*;

    /// D5(a): the switch is the one constant; a build without `team-write` (every app build) says no.
    /// Negative control: `team_enabled` returning `true` -> FAIL in the plain build.
    #[test]
    fn team_enabled_is_the_write_mesh_addr_constant() {
        assert_eq!(team_enabled(), batman_proto::teamview::WRITE_MESH_ADDR);
        assert_eq!(team_enabled(), cfg!(feature = "team-write"));
    }
}
