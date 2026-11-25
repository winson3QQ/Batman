# Review A, round 6 (final): cfgsave-stage-enospc, dcb92f8..f49107a against design v6

Reviewer A.
- **Clone:** my own fresh clone `<home>/rev-cfgA6` (cloned from `Batman-app`, HEAD `f49107a`), run in WSL as root.
- **Constraints kept:** no commit, no stash, nothing aimed at `/dev/null`.
- **Feed vs deploy copy:** `cmp` shows they are identical.
- **Concurrency:** other reviewers' runs were going at the same time. The new host `flock` serialized them (each of my runs waited 59–112 s for the lock).

**Verdict: APPROVE.** No BLOCKER and no MAJOR. My r5 F1 (teardown leak) is closed and has a working negative control. Two MINOR notes below.

## Runs

| # | What | Result |
|---|---|---|
| H ×2 | HEAD test, HEAD script, `CFGSAVE_REQUIRE_DM=1` | ✅ `PASS=106 FAIL=0` ×2. Each printed `private mount namespace mnt:[…] (host mnt:[4026532217])` and `host lock … taken after 89 / 98 s` |
| V1 | HEAD test, 6d65ecd script | ✅ `PASS=73 FAIL=33`. Your run gave 74/32; the difference is the known timing-dependent eio6 "last line `rm:`" case |
| LEAK | `CFGSAVE_TEST_LEAK=1` (the test's own test: the device is held open after exit) | ✅ `PASS=106 FAIL=1`: `FAIL teardown: LEAK dm:cfgenospc-tmp.k7jRiUTYp3(1 open) loop:/dev/loop0 — left on the host`. Its last line is the FAIL summary, so the stub runner sees red. I removed that one device myself afterwards (`dmsetup remove --retry`, then `losetup -d`) |
| MU | Mutant: the script never unmounts (all 8 `umount "$MNT" 2>/dev/null` changed to `true`) | ✅ `PASS=1 FAIL=100` in 61 s, with no hang and no retry loop. Every case fails with `setup: <dev> still mounted` plus evidence (`still MOUNTED at the start of a case`, the dmsetup open count, holders) |
| NT | Node tools under qemu (a53 rootfs) in a private namespace: mount-utils `/usr/bin/mount` (it comes before busybox in OpenWrt's `PATH`), busybox `mount`, `ls -lnL`, `awk`, `logger` | ✅ See below |
| N | Full test under the node's busybox (a53, qemu-user) | ✅ `PASS=106 FAIL=0`, 742 s |

## Your points

1. **The teardown MAJOR is closed.**
   - `cleanup()` now runs `settle`, then `dmsetup remove --retry`, then `settle` again. It then **proves** the dm device and the loop are gone (`dmsetup info`, `losetup -j`, no mounts left under `$W`). On a leak it ends with `FAIL teardown: LEAK …` and exit 1.
   - Negative control: the LEAK run above.
   - The dm name now comes from `$W` (`cfgenospc-tmp.XXXX`), the host `flock` serializes runs, and the private mount namespace (checked: our namespace ≠ pid 1's) handles the setup hold the fixer attributed in v6 §8.
2. **The bounded mkfs retry cannot hide a real umount bug in the script.**
   - `mkfs_p5` retries only while `devfree` holds, meaning the device is not mounted in our namespace. The script runs inside that same private namespace, so any mount it leaves behind is visible to `devfree`, and the case FAILs at once with evidence.
   - Negative control: MU (100 FAILs, no retries).
   - The only holds a retry can wait out are outside our mounts (udev's probe), and it gives up after 15 tries.
3. **The logger lines carry nothing sensitive.** They contain the fixed text plus `$MNT`, which is our own run-dir mount point (`/tmp/run/batman/cfgsave-mnt.XXXX`). No device content, no config value, no key.
4. **The node has every tool the new path uses.** Checked under qemu with the a53 rootfs.
   - **Which mount runs:** on the node, `mount` / `umount` resolve to **mount-utils `/usr/bin/mount`**, because `PATH` is `/usr/sbin:/usr/bin:/sbin:/bin` and busybox is `/bin/mount`. `logger`, `awk`, `ls` and `hexdump` are busybox.
   - **Both mounts:** `mount --bind` rc 0, then `mount -o remount,bind,ro` rc 0. The bind's mountinfo line is `mm=7:1 root=/ opts=ro,relatime`, and a write into it is refused.
   - **The script's helpers:** with node busybox, `p5_mm` gives `7:1` (the host agrees) and the `p5_mountinfo root` awk finds the rw mount. `logger -t batman-config-save -p daemon.warn …` rc 0.
   - **End to end:** the real `--check` on a busy p5, run with node busybox for `sh` and every applet plus node mount-utils for `mount` / `umount`, printed `p5 is mounted at … — compared through a read-only bind of that mount` then `p5 fresh`, rc 0. It left 0 mounts of its own behind.

## Findings

- **F1 — MINOR (product):** the result of `mount -o remount,bind,ro "$MNT"` is ignored. If the remount fails, the bind stays rw. `--check` never writes, so nothing is harmed, but the message still says "read-only bind". Fix: on failure, either `umount` and take the rc 5 path, or check `ro` in our mountinfo line together with major:minor.
- **F2 — MINOR (test):** the private namespace and the host lock make every run serialized and heavier (about 200 s per run this round, including lock waits). Nothing to fix. It is worth one line in the PR's test section: CI runs a single instance, so there is no lock wait.

## Leftovers / not done

- ✅ At the end, `dmsetup ls` printed `No devices found`, `losetup -a` was empty, and `/dev/null` was still `character special file 1:3`.
- The device the LEAK control kept on purpose was removed by me after the run.
- ❌ Not done:
  - no run on a node;
  - no GitHub CI (whether the runner can load dm-flakey, and the private-namespace re-exec there, are still unverified);
  - no sbx.
