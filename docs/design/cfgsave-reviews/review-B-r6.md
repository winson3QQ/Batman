# Review B, round 6 — cfgsave-stage-enospc (dcb92f8..f49107a, design v6)

Scope: the round-6 change in full (0fd4591 product + tests, 2d2f1fc private-namespace re-exec, 51ee578 / f49107a design
v6), checked against the whole design v6. Fresh clone `<home>/rev-cfgB6` (f49107a), WSL Ubuntu-24.04 as root.
I did not change the product code; I only read it. No node was touched, and `/dev/null` is still `character special file 1,3`.

**Verdict: APPROVE.** No BLOCKER and no MAJOR; two MINORs that are optional before the PR.

## Evidence

| # | What | Result |
|---|---|---|
| R1 | New test, product HEAD, `CFGSAVE_REQUIRE_DM=1`, ×2 | ✅ `PASS=106 FAIL=0` both. `private mount namespace mnt:[4026532287] (host mnt:[4026532217])`, host lock taken after 0 s |
| R2 | Product e30f746 (round-5 negative control) | ✅ `PASS=103 FAIL=3`: stacked tmpfs → rc 7 (read the tmpfs); **named fake → rc 0 `fresh` on a corrupt p5** (this confirms the outcome I only inferred in round 5); subdir bind → generic text |
| R3 | **Mutant:** HEAD with the `mine == p5_mm /` verification removed | ✅ `PASS=105 FAIL=1`: `stacked tmpfs: --check rc 7` (the tmpfs taken as an *unseeded* p5; rc 7 is a `skip:` at the OTA gate). The verification is what closes it |
| R4 | Product 6d65ecd | `PASS=74 FAIL=32` |
| R5 | `deploy/` vs `feed/` | ✅ identical |
| R6 | `mount --bind` + `mount -o remount,bind,ro` on the bind of a rw ext4 mount, with **host busybox 1.36.1, the node's busybox (the pinned bcm2711 payload's `bin/busybox` under `qemu-aarch64-static`; both SoC builds `CONFIG_FEATURE_MOUNT_FLAGS=y`), and util-linux** | ✅ all three: bind rc 0, remount rc 0. The other mount stays `rw`, **superblock `super=rw`**, and it is still writable. The bind is `ro` and a write through it gets EROFS |
| R7 | Leftover devices after all runs | ✅ `dm=0 loop=0` |

## The coordinator's questions

- **Can the bind path change p5's superblock flags?** No. `remount,bind,ro` is MS_REMOUNT|MS_BIND|MS_RDONLY, which changes
  only our vfsmount's flag; R6 shows `super=rw` and the other mount still writable with all three `mount`
  implementations, including the node's.
- **Can it leave a mount behind?**
  - **Verified as p5:** the bind is our `$MNT`, and the EXIT `cleanup` unmounts it (now logging a failed umount).
  - **Not p5:** an immediate `umount`, then `exit 5`, and `cleanup` tries again.
  - **Unmounting the bind only detaches our vfsmount.** The other process's mount is untouched; the test's busy-case
    teardown unmounts it afterwards, and the leak check finds nothing (R7).
- **What if our private mountpoint already holds something?**
  - `$MNT` is a fresh `tmpd` directory in the 0700 run dir. The three `ro,noload` attempts on it just failed, so nothing
    of ours is mounted there.
  - Even if something were, the bind stacks on top. `tail -n 1` of the mountinfo lines for `$MNT` takes the topmost
    (newest) one, and its `major:minor` and root must match p5. So whatever is underneath cannot be read.
- **Could the private-namespace re-exec hide a product bug?** No.
  - The product and the test run in the same namespace, so the product sees exactly the mounts it and the test make,
    which is what it sees of its own and other writers' mounts on a node.
  - Private propagation is, if anything, closer to OpenWrt than WSL's systemd-shared root.
  - A mount the product leaks is still visible inside the namespace. `devfree` FAILs the next case with evidence, and
    the teardown checks mounts, dm and loop before the namespace dies.
  - What the namespace removes is only outside processes copying our mounts. Those are host noise, not product behaviour.
  - The `/run` flock is the same tmpfs inode in every namespace, so instances still queue.

## Findings

### MINOR-1 — The rc of `remount,bind,ro` is ignored, but the message says "read-only bind"

If the remount ever failed, `--check` would read through a rw bind. That is harmless: `--check` only reads (cleanup's
`sync` writes nothing of ours). But the text would be wrong. **Fix:** if the remount fails, `umount` the bind and return
rc 5 `busy … could not be compared`, or drop "read-only" from the message. R6 shows it does not fail on the shipped busybox.

### MINOR-2 — The harness runs the product's `mount` with util-linux, not busybox

`mount` and `umount` are not in the busybox applet list (`cfgsave-stage-enospc.sh:115`). So in CI the new bind/remount
path is exercised with util-linux. R6 confirms the node's busybox behaves the same, and design §8 reports a qemu run.
**Fix (optional):** add `mount umount` to the applet list so CI exercises busybox's option parsing too.

## Not done

- ❌ No CI run (branch local) and no node run.
- I did not run `CFGSAVE_TEST_LEAK=1`, the test-of-the-test for the LEAK FAIL; I relied on the design.
- The f49107a attribution of the setup hold (a mount copy held by a process in another namespace) rests on the fixer's
  evidence (`/proc/2424576/mountinfo` held `254:0`). I did not see that pid myself. It is consistent with my round-5
  observations. The private namespace removes the mechanism either way.
