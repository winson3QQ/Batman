# Design review: what every design must state, and what the reviewer checks

Every change gets a **review level** (L0–L3, below). An L2 or L3 design, whether a feature or a fix, passes an adversarial review before any code is written or anything goes onto a node.

This file is the review checklist. Give it to every independent reviewer, together with the design doc. Hardware designs (schematics, power tree, the HAT) use [`REVIEW-hw.md`](REVIEW-hw.md) instead.

## Review level (decided 2026-11-25)

The level depends on **what the change touches**, not on its label, its size or the folder it is in. It costs too much to run the full process on every change, and too little review on the wrong change costs more.

| Level | Applies to | Design | Adversarial review | Before the PR | Test evidence |
|---|---|---|---|---|---|
| **L0 docs** | files that are not code and set no rules: roadmap, plans, explanations, typos, issue housekeeping. Also a rule-setting file edited only to match a decision already made elsewhere (a rename, a milestone sync, a link) | none | none | self-check: links work, the text matches the current state of the repo and GitHub | "docs only, n/a" |
| **L1 presentation** | a diff that changes **only** what the user sees: visible text, layout, styling, widget structure, assets; comment-only edits that are not lint or analyzer directives | a few lines of plan in the issue | none | `/code-review medium`, which also confirms the diff is presentation only | a screenshot, or a run on one node |
| **L2 normal** | anything that hits no L3 trigger; adding a new validation test case; tightening a check; changing the rules in a rule-setting file; follow-up fixes of MINORs left by an approved L3 review | design doc; items 1–3 may be short only when no state is shared across components. For a rule-setting file the PR diff is the design | **one** reviewer, at most 2 rounds | `/code-review high` (rule-setting docs: n/a) | on a node, with a negative control (rule-setting docs: n/a; the reviewer checks them against the files they govern) |
| **L3 critical** | anything that hits an L3 trigger | full design, items 1–5 | **two** independent reviewers, until no BLOCKER or MAJOR is open | `/code-review high` **and** `/security-review` (always) | on a node, negative controls, untested parts listed |

**L3 triggers.** Touching any one of these makes the change L3:
- keys, certificates, the 608B, OTP, LUKS keys;
- provisioning, claiming, members, permissions;
- the boot chain, A/B, OTA, autocommit, LKG;
- mesh, network, firewall, the BLE protocol;
- **any new or changed input reachable from the network, BLE or mesh**: a CGI (for example `deploy/provisioning/www/*`), a port (including the OTS gateway), a message format;
- services that run as root; payload / guardian; persistent state on p5 / p6;
- kernel and driver patches (`patches/`), device-tree overlays (`overlays/`);
- performance and resource limits. A performance change also carries before/after numbers from a node; measurement matters more here than argument;
- new or changed dependencies and anything else in the supply chain (gate 10, #46);
- build and card scripts, the firmware allowlist, the shared A/B files (`CLAUDE.md` § 改共用 A/B 程式), CI workflows;
- anything that writes state to the rootfs overlay (gate 13);
- **weakening the validation gate**: changing the runner or preflight (`scripts/daily-validation.sh`, `scripts/dv-preflight.sh`), changing or removing an existing suite in `scripts/dv/*` or a `check-*` / `test-*` / `lint-*` CI check, widening an allowlist or `rundir-paths.txt`, adding a known-failure entry or extending its expiry. The #290 harness-PR rules in `CLAUDE.md` § 驗證 apply on top.

**Rules.**
- **Proposing the level.** The author proposes the level in the plan, with the reason (which trigger, if any). The user can change it when approving the plan.
- **Changing the level.** During the work the level can only go **up**. The author or a reviewer raises it when the change turns out to touch more. Only the user can lower it. If the level goes up after code exists, the design review at the new level runs before more code is written, and the existing code is reviewed again at that level.
- **L1 is decided by the diff, not the folder.** Most files in `app/lib/ui/` also call flows, the sealed store or the node link (`remove_pages.dart` revokes members, `send_key.dart` sends keys, `dev_pages.dart` edits ssh keys). A diff that adds, removes or changes a call into `src/`, the Rust bridge, a store, a link, a flow, or how their results are handled is not L1. If that flow is keys, members or provisioning, it is L3. Node code, BLE characteristics and the node's status page or CGI are never L1.
- **Tests.** A unit or widget test changed in the same PR as the code it tests takes that code's level (a wording change that updates a `find.text` test stays L1). For the validation gate: adding a new suite that proves itself (old FAIL as the negative control, new PASS, per #290), tightening a check, or removing a known-failure entry with PASS evidence is L2. Weakening the gate is L3 (trigger above).
- **Shared state across components** (a uci key, file, flag or log line that another tool reads) is the #274 class of bug: at L2, items 1–3 are written in full. Many "UX" issues are not L1: #329's App work ended up touching the rotating id and ssh keys. Anything with correctness semantics, such as an honest message-delivery status (#387), is at least L2.
- **Rule-setting files** set rules for everything else: `CLAUDE.md`, `docs/dev-process.md`, `docs/threat-model.md`, `docs/design/REVIEW.md`, `docs/design/REVIEW-hw.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `docs/boards-and-builds.md` (its §6 is the CI `paths` list), `docs/storage-architecture.md` (the write-placement contract, gate 13) and `docs/VERSIONS.md`. Changing a rule in them is L2; a sync to a decision already made is L0. Design docs are reviewed as part of their own change's level.
- The PR states its level in the **Review** section of the PR template.

**Rounds and escalation.**
- A round means: every reviewer of that level reads the **whole** design again (the #274 lesson below), and the author fixes what they found.
- **L2:** if a BLOCKER or MAJOR is still open after round 2, the author stops and asks the user: raise to L3 (a second reviewer joins and round counting continues, so the next round is round 3), or the user decides otherwise.
- **L2 and L3:** from round 3 on, open MINORs go into a findings register (like `264-review-register.md`) or the PR's Review section, and no longer trigger a full re-review. Only an open BLOCKER or MAJOR does.
- **L3:** if a BLOCKER or MAJOR is still open after round 5, stop and report to the user. The user decides: keep going, split the issue, or accept the residual risk in writing.

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
   - each supported board: bcm2711 (Pi 4); bcm2710 only while its build is kept (`docs/boards-and-builds.md`; the Pi 3A+ product was excluded 2026-11-17); CM4 once its image exists (#413): eMMC instead of an SD card, rpiboot rescue (#415), OTP.

   Mark any row that does not apply with the reason.
4. **Assumptions about other code.** List every behaviour of another component the change relies on, upstream ones included (procd, docker, busybox, OpenWrt sysupgrade). Each needs evidence: `file:line` in the source, or output captured on a node. "Should be" is not evidence. Unverified assumptions are checked with a read-only probe on a node before the design is approved.

5. **Security.** This is part of the design review, not a step after the code is written. State:
   - **Assets and actors.** Assets: control of the node (commit/revert, slot, reboot, halt), radio and mesh, keys and certs (the 608B slots and its config lock, the CM4 OTP, the LUKS key, the image-signing key), tenant data, availability. Go through each actor:
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

   Before the PR, every L3 change also gets `/security-review`, whatever it touches. That review complements the design review and does not replace it.

When items 1–3 may be short is set in § Review level: at L2, and only when no state is shared across components. Then one sentence that says so and why is enough.

The weight of the review depends on how much shared state the change touches, not on how big the change is.

## The reviewer

- Reviews the **whole** design, not only the newest revision. The first task is to find rows missing from the lifecycle matrix and resources missing from the ownership list.
- Starts from what happens in the field, not from the list of points the author asks about.
- Checks each claimed assumption against the source, or against read-only output from a node.
- Attacks the design as each actor in item 5, especially a local non-root process and a compromised tenant.
- Checks that every claim has a test with a negative control, meaning a test that would fail without the change.
- Outputs numbered findings (BLOCKER / MAJOR / MINOR), each with a concrete failure scenario, evidence and a fix, and then a verdict: APPROVE / APPROVE-WITH-CHANGES / REJECT.

If a BLOCKER or MAJOR finding is open, change the design and review the whole document again. Reviews are saved in `docs/design/<issue>-reviews/`. The round limits for L2 and L3 are in § Review level.
