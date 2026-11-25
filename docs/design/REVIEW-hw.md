# Hardware design review: what every hardware design must state, and what the reviewer checks

This is the hardware counterpart of [`REVIEW.md`](REVIEW.md). Give it to every independent reviewer, together with the design (spec, schematic, BOM, measurement plan).

It covers the hardware stages of roadmap v5: the jumper and eval-board work and the power-only board in v2.2, the CM4 measurements in v2.3, and the HAT v2 design in v2.4 (requirements freeze #417, final design #227). Software that runs on the hardware is still reviewed with `REVIEW.md`.

## Why

A board mistake costs a fab run and weeks. A software mistake costs a commit. HAT v1 was laid out but never fabricated, so HAT v2 has no board of our own that has been proven. Every assumption in it must come from a datasheet or from a measurement on the bench (v2.2, v2.3) before the Gerber goes out.

## Review level

| Design | Level (`REVIEW.md` § Review level) |
|---|---|
| A measurement plan on eval boards or jumpers (v2.2, v2.3) | L2: one reviewer, at most 2 rounds |
| **HAT v2 requirements freeze** (#417) | L2 |
| The power-only board (#408), or any other board we fabricate | L3: two reviewers, until no BLOCKER or MAJOR is open |
| **HAT v2 final spec, schematic, layout and Gerber** (#227), before the fab order | L3 |

For hardware, the level sets the number of reviewers and the round and escalation rules in `REVIEW.md` § Review level. The evidence comes from this file (pass limits written before measuring, item 3; the schematic and layout record, item 8), not from the software columns of the level table. `/code-review` and `/security-review` apply only to software in the same PR. Item 8 applies once a schematic exists; the requirements freeze (#417) checks items 1, 2 and 7. The gate for the fab order is: v2.1–v2.3 are done, and the #227 review has no open BLOCKER or MAJOR.

## The design must state

1. **Requirements trace.** Every requirement in the HAT v2 spec (`docs/design/hat-v2-spec.md`, in PR #303, not yet merged) maps to a part or net in the schematic, and to the verification item that proves it (spec §14, done in v3.0 by #419). A requirement with no test is a finding.
2. **Assumptions with evidence.** Every assumption (spec §11) carries a datasheet reference (document, revision, page or table) or a bench measurement with its raw data. "Typical" values are not evidence for a worst case. The datasheet checks are #418.
3. **Power tree.** For every rail:
   - source, regulator and worst-case current, with margin;
   - start-up order and timing, and inrush;
   - behaviour on brown-out, battery removal, hard power loss, and USB-only power;
   - protection: reverse polarity, overcurrent, ESD on exposed connectors;
   - how it is measured (eval boards #407, power-only board #408), with the pass limit written **before** the measurement.
4. **Pin and bus ownership.** One table for every pin of the host connector (40-pin, or CM4) and every I2C address (#411). For each pin:
   - its single owner: a driver, a service, or the I/O expander (#409);
   - level, pull, and default state;
   - its state at power-on, during reset, during firmware boot, before its driver loads, and after an OS crash.

   Two owners on one pin, or a pin whose state before software runs can do harm (key up the radio, cut power, light a "healthy" LED), is a finding.
5. **RF coexistence.** HaLow, LoRa, GNSS and BLE on one box:
   - antenna placement and isolation;
   - desense measured with every radio transmitting;
   - transmit power within the regulatory limit for each target market (#412 for Taiwan).
6. **Thermal and mechanical.** Worst-case ambient inside the enclosure, the hottest parts, connector strain, and what the user can touch.
7. **Security of the hardware.** Go through these actors from `REVIEW.md` item 5: physical capture of a node, supply chain, our own mistakes.
   - Where the 608B sits, and whether its bus is reachable from a test point or connector.
   - Debug ports (UART, SWD, USB boot / rpiboot) and how they are closed in production.
   - Boot and OTP pins on the CM4.
   - No China-origin parts (#46), and a second source for each critical part.
8. **Schematic and layout checks.** Attach the output or the record of each:
   - ERC and DRC output, with every waiver explained;
   - symbol ↔ footprint ↔ datasheet pinout, including pin 1 and package variant;
   - voltage domains and level shifting at every interface (CM4 GPIO banks, 1.8 V vs 3.3 V);
   - back-feeding: no rail or I/O can power a part that is off (USB, battery, host 5 V, GPIO into an unpowered part);
   - decoupling and bulk capacitance per datasheet;
   - RF: trace impedance, stackup, keepout, antenna feed (spec §6.3);
   - high-speed routing: USB, SDIO, SPI to the radios;
   - BOM ↔ schematic match (values, ratings, part numbers);
   - Gerber, drill and fab notes, reviewed against the layout;
   - the ESD and EMC test plan.
9. **The hardware/software boundary.** For every signal that software drives or reads (overlays in `overlays/`, drivers, services), the ownership, contract and lifecycle items 1–3 of `REVIEW.md`: who drives it, what state it is in before its driver loads, and what the software does when the part is missing or faulty.
10. **Manufacture and test.** Test points needed by the assembly verification (#419), BOM availability and lifecycle, and the factory steps.

A board that only breaks out existing parts (a jumper adapter) may replace items 3 and 5–10 with one sentence that says why they do not apply. Item 4, pin ownership and power-on state, always applies: that is the risk in jumper work such as #409 and #410.

## The reviewer

- Reviews the **whole** design: spec, schematic and BOM together, not only the newest change.
- Checks each claim against the datasheet page or the raw measurement data. A claim with no source is a finding.
- Starts from what happens in the field: a dead battery, a dropped node, a captured node, a hot vehicle.
- Checks that every measurement has a pass limit written before it was taken, and a way to show the setup can detect a failure (for example, the scope catches a brown-out when the protection part is removed).
- Outputs numbered findings (BLOCKER / MAJOR / MINOR), each with a concrete failure scenario, evidence and a fix, and then a verdict: APPROVE / APPROVE-WITH-CHANGES / REJECT.

If a BLOCKER or MAJOR finding is open, change the design and review the whole design again. Reviews are saved in `docs/design/<issue>-reviews/`.
