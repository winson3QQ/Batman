# Design review: what every design must state, and what the reviewer checks

Every design, whether a feature or a fix, passes an adversarial review before any code is written or anything goes onto a node.

This file is the review checklist. Give it to every independent reviewer, together with the design doc.

## Why

Most whole-machine bugs so far came from components that are each correct in isolation, but whose unstated assumptions about each other conflict:

| Issue | What went wrong |
|---|---|
| #274 | Three parties owned container start/stop: docker's restart policy, procd, and the guardian. An OTA fell in the gap between them. |
| #280 | Many scripts trusted `/tmp` as if only root could write there. |
| #265 | A canary latched its first success, assuming that a pass once means a pass for the rest of the boot. |

Unit-level tests cannot catch this class of bug. Only a design that writes the contracts down can.

Two lessons came from #274:
- Three review rounds said "system-wide" in their prompts, yet all accepted "an OTA is not a graceful stop" without asking what then happens to the containers. A reviewer given a list of attack points checks that list and nothing else.
- A review of only the newest section missed the same thing.

## The design must state

1. **Ownership.** For every resource the change touches (container, state file, flag, partition, lock, timer or deadline), name the single owner that may change it, and the components that only read it. Two writers on one resource is a finding.
2. **Contracts.** For every interface (file, flag, exit code, socket, uci key, log line another tool parses), state:
   - who writes it and who reads it;
   - when it is valid, and its format;
   - what happens when it is missing, stale or malformed (fail-open or fail-closed, and why);
   - who can write the path (trust boundary).
3. **Lifecycle matrix.** One row per path the change can meet. For each row, give the behaviour today, the behaviour after the change, and the test that proves it. The rows are:
   - first boot / firstload;
   - boot;
   - clean shutdown;
   - reboot;
   - OTA (sysupgrade stage 1 / stage 2);
   - autocommit commit and revert;
   - power loss;
   - restart of the component itself;
   - restart of each component it depends on (dockerd, procd service, network);
   - crash or crash loop;
   - downgrade to an image without the change;
   - both boards (bcm2711 / bcm2710).

   Mark any row that does not apply with the reason.
4. **Assumptions about other code.** List every behaviour of another component the change relies on, upstream ones included (procd, docker, busybox, OpenWrt sysupgrade). Each needs evidence: `file:line` in the source, or output captured on a node. "Should be" is not evidence. Unverified assumptions are checked with a read-only probe on a node before the design is approved.

5. **Security.** This is part of the design review, not a step after the code is written. State:
   - **Assets and actors.** Assets: control of the node (commit/revert, slot, reboot, halt), radio and mesh, keys and certs, tenant data, availability. Go through each actor:
     - remote attacker over the mesh or WiFi;
     - local non-root process;
     - compromised tenant or container;
     - physical capture of a node or SD card;
     - supply chain;
     - our own mistakes.
   - **Attack-surface delta.** Every new or changed input (file or path, port, CGI, uci key, env var, mesh message, CLI argument), who can reach it, and how it is validated.
   - **Privilege.** What runs as root and why. Root code that reads or writes anything a non-root process can write (`/tmp`, `/dev/shm`, world-writable dirs, symlinks, hardlinks, predictable names) is a finding. Use the root-only run dir and `opf` from #280 (once merged).
   - **Secrets.** Where keys, PSKs and certs live, who can read them, and how they are rotated or revoked. Never in logs, URLs, world-readable files or the public repo.
   - **Failure mode.** Fail-secure by default. Any fail-open needs a stated reason.
   - **Verification.** A negative test that shows the attack is blocked, for example running it as a non-root process (as #280's `tmp-trust-280` will do).

   Before the PR, the code also gets `/security-review`. That review complements the design review and does not replace it.

A change that touches no shared state (internal to one component) may replace 1–3 with one sentence that says so and why.

The weight of the review depends on how much shared state the change touches, not on how big the change is.

## The reviewer

- Reviews the **whole** design, not only the newest revision. The first task is to find rows missing from the lifecycle matrix and resources missing from the ownership list.
- Starts from what happens in the field, not from the list of points the author asks about.
- Checks each claimed assumption against the source, or against read-only output from a node.
- Attacks the design as each actor in item 5, especially a local non-root process and a compromised tenant.
- Checks that every claim has a test with a negative control, meaning a test that would fail without the change.
- Outputs numbered findings (BLOCKER / MAJOR / MINOR), each with a concrete failure scenario, evidence and a fix, and then a verdict: APPROVE / APPROVE-WITH-CHANGES / REJECT.

If a BLOCKER or MAJOR finding is open, change the design and review the whole document again.
