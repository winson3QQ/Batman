#!/usr/bin/env python3
"""profile-to-manifest.py — render a payload's OPERATIONAL siblings into flat, node-consumable
artifacts (#167 Increment 1). App-agnostic companion to profile-to-flags.py (confinement flags)
and profile-to-fw4.py (firewall). Reads deploy/<app>/profile.yaml `images / network / lifecycle /
volumes` (the emitter-IGNORED operational blocks) and writes THREE flat files the busybox node
consumes — the node NEVER parses YAML; this runs on the dev machine / in CI:

  deploy/<app>/<app>.manifest              the ordered container list + per-container run facts,
                                           consumed by /usr/bin/payload-run (the generic runner)
  deploy/<app>/<app>.net.alloc             the arbiter registry record (PORTS/SUBNET/ZONE/BRIDGE),
                                           consumed by /usr/bin/payload-arbiter (collision refusal)
  deploy/<app>/batman-payload-<tenant>.init  the 4-line per-tenant procd stub that sources the
                                           generic guardian (/usr/lib/batman/payload-guardian.sh);
                                           lands on p6 under apps/<tenant>/, restored every boot by
                                           the #192 glob (95-batman-storage restore_payload_guardians)

The manifest is line-oriented (one `DIRECTIVE value...` per line, CONTAINER..ENDCONTAINER blocks)
so payload-run parses it with `while read` in busybox ash — no YAML, no jq.

Usage:  profile-to-manifest.py <app>            # writes the three files
        profile-to-manifest.py <app> --check    # print all three to stdout (CI diff), write nothing
"""
import sys, pathlib
try:
    import yaml
except ImportError:
    sys.exit("PyYAML required (pip install pyyaml)")

REPO = pathlib.Path(__file__).resolve().parent.parent


def resolve_containers(doc, app):
    """Flatten images[].containers[] into name -> spec, tagging each with its image + hardening env.

    A container's hardening env is `<name>.hardening.env` when <name> is an infra_values key
    (per-infra confinement), else the app-wide `<app>.hardening.env` (the `values:` block). NB the
    app-wide env is named by the DEPLOY-DIR name (`app`), NOT the tenant — profile-to-flags.py emits
    `deploy/<app>/<app>.hardening.env`, and a tenant's dir may differ from its `tenant:` (ots vs
    opentakserver).
    """
    infra = set((doc.get("infra_values") or {}).keys())
    out = {}
    for img in doc.get("images", []) or []:
        ref = img.get("ref")
        for c in img.get("containers", []) or []:
            name = c["name"]
            harden = f"{name}.hardening.env" if name in infra else f"{app}.hardening.env"
            out[name] = {
                "name": name,
                "image": ref,
                "ip": c.get("ip"),
                "hostname": c.get("hostname", name),
                "entrypoint": c.get("entrypoint"),          # list of tokens or None
                "env": c.get("env") or {},                  # per-container env map
                "volumes": c.get("volumes") or [],          # [{name,path,chown?,chown_image?}]
                "mounts": c.get("mounts") or [],            # [{src,dst,ro?}] read-only config bind-mounts
                "harden": harden,
            }
    return out


def render_manifest(doc, app):
    tenant = doc["tenant"]
    net = doc.get("network", {}) or {}
    br = net.get("bridge", {}) or {}
    life = doc.get("lifecycle", {}) or {}
    order = life.get("order") or []
    health = life.get("health", {}) or {}
    restart = life.get("restart", "on-failure:5")
    env_common = doc.get("env_common", {}) or {}
    # secrets (#167 §5): file-delivered secrets mount read-only into named containers. `source`:
    #   self-signed = app makes it in its own volume (no delivery, emit nothing)
    #   seed        = restored from p5 by 96-batman-config-migrate into apps/<tenant>/secrets/<name>
    #   file / ota  = placed under apps/<tenant>/secrets/<name> (ota deferred to #116)
    # Each secret names {name, source, mount, into:[container...]}. Emitted as a per-container SECRET
    # line; payload-run resolves apps/<tenant>/secrets/<name> at runtime and bind-mounts it ro.
    def container_uid(name):
        # the run_as uid the target container runs as — a 0600 root secret is unreadable by a
        # non-root container, so delivery must chown the secret to this uid (payload-run does it).
        infra = doc.get("infra_values") or {}
        u = (infra[name].get("user") if name in infra else (doc.get("values", {}) or {}).get("user")) or {}
        return u.get("run_as")

    secrets_by_ctr = {}
    for s in (doc.get("values", {}) or {}).get("secrets") or []:
        if not s.get("mount") or s.get("source") in (None, "self-signed"):
            continue
        for ctr in (s.get("into") or []):
            secrets_by_ctr.setdefault(ctr, []).append((s["name"], s["mount"], container_uid(ctr)))
    containers = resolve_containers(doc, app)
    # if lifecycle.order is empty, fall back to declared container order
    if not order:
        order = list(containers.keys())

    L = []
    a = L.append
    a(f"# GENERATED by scripts/profile-to-manifest.py from deploy/{app}/profile.yaml -- DO NOT EDIT BY HAND.")
    a("# Consumed by /usr/bin/payload-run (the generic payload orchestrator, #167). Line-oriented for busybox.")
    a(f"TENANT {tenant}")
    # docker network name: default <tenant>-net, but a tenant migrating off a bespoke script can pin
    # its EXISTING network name (network.docker_name) so payload-run REUSES it (same kernel bridge)
    # instead of failing to create a second network on an already-taken bridge name.
    a(f"NETWORK_NAME {net.get('docker_name') or tenant + '-net'}")
    if br.get("name"):
        a(f"BRIDGE {br['name']}")
    if br.get("subnet"):
        a(f"SUBNET {br['subnet']}")
    if net.get("zone"):
        a(f"ZONE {net['zone']}")
    a(f"RESTART {restart}")
    for name in order:
        c = containers.get(name)
        if not c:
            sys.exit(f"{tenant}: lifecycle.order names '{name}' but no images[].containers[] entry defines it")
        a("")
        a(f"CONTAINER {c['name']}")
        a(f"IMAGE {c['image']}")
        if c["ip"]:
            a(f"IP {c['ip']}")
        a(f"HOSTNAME {c['hostname']}")
        a(f"HARDEN {c['harden']}")
        # env_common applies to APP containers only (not infra) — an infra container has its own
        # env map; the app containers share env_common plus their own.
        is_infra = c["harden"] != f"{app}.hardening.env"
        merged_env = {} if is_infra else dict(env_common)
        merged_env.update(c["env"])
        for k, v in merged_env.items():
            a(f"ENV {k}={v}")
        if c["entrypoint"]:
            a("ENTRYPOINT " + " ".join(str(t) for t in c["entrypoint"]))
        for v in c["volumes"]:
            # VOLUME <name>:<path>[:<chown_uid:gid>[:<chown_image>]]
            spec = f"{v['name']}:{v['path']}"
            if v.get("chown"):
                spec += f":{v['chown']}"
                if v.get("chown_image"):
                    spec += f":{v['chown_image']}"
            a(f"VOLUME {spec}")
        for m in c["mounts"]:
            ro = ":ro" if m.get("ro", True) else ""
            a(f"MOUNT {m['src']}:{m['dst']}{ro}")
        for sname, smount, suid in secrets_by_ctr.get(name, []):
            a(f"SECRET {sname} {smount} {suid}" if suid is not None else f"SECRET {sname} {smount}")
        h = health.get(name)
        if h:
            a(f"HEALTH {h}")
        a("ENDCONTAINER")
    return "\n".join(L) + "\n"


def render_net_alloc(doc, app):
    tenant = doc["tenant"]
    net = doc.get("network", {}) or {}
    br = net.get("bridge", {}) or {}
    ports = sorted({str(p["host_port"]) for p in (net.get("publish") or [])})
    L = [
        f"# GENERATED by scripts/profile-to-manifest.py from deploy/{app}/profile.yaml -- DO NOT EDIT BY HAND.",
        "# Arbiter registry record (#167 §3). payload-arbiter refuses a tenant whose PORTS/SUBNET/ZONE/BRIDGE",
        "# intersect any OTHER installed tenant's net.alloc. Flat + greppable (busybox).",
        f"TENANT={tenant}",
        f"PORTS={' '.join(ports)}",
        f"SUBNET={br.get('subnet', '')}",
        f"ZONE={net.get('zone', '')}",
        f"BRIDGE={br.get('name', '')}",
    ]
    return "\n".join(L) + "\n"


def render_guardian_init(doc):
    tenant = doc["tenant"]
    # a 4-line procd stub: the heavy #156 guardian logic is the shared, image-baked
    # /usr/lib/batman/payload-guardian.sh; this per-tenant init just names the tenant. It lands on
    # p6 (apps/<tenant>/) and the #192 glob restores + enables + starts it after every A/B flash.
    return (
        "#!/bin/sh /etc/rc.common\n"
        f"# GENERATED by scripts/profile-to-manifest.py for tenant '{tenant}' -- DO NOT EDIT BY HAND.\n"
        "# Generic payload guardian (#156/#167): the shared logic is /usr/lib/batman/payload-guardian.sh;\n"
        "# this stub only names the tenant. Restored after A/B flash by the #192 glob (95-batman-storage).\n"
        "START=99\n"
        "STOP=10\n"
        "USE_PROCD=1\n"
        f"PAYLOAD_TENANT={tenant}\n"
        ". /usr/lib/batman/payload-guardian.sh\n"
    )


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    app = sys.argv[1]
    check = "--check" in sys.argv[2:]
    prof = REPO / "deploy" / app / "profile.yaml"
    if not prof.exists():
        sys.exit(f"no profile: {prof}")
    doc = yaml.safe_load(prof.read_text(encoding="utf-8")) or {}
    tenant = doc.get("tenant")
    if not tenant:
        sys.exit(f"{app}: profile has no `tenant:`")

    outputs = [
        (f"{app}.manifest", render_manifest(doc, app)),
        (f"{app}.net.alloc", render_net_alloc(doc, app)),
        (f"batman-payload-{tenant}.init", render_guardian_init(doc)),
    ]
    if check:
        for fname, body in outputs:
            sys.stdout.write(f"==> {fname}\n")
            sys.stdout.write(body)
        return
    for fname, body in outputs:
        dst = REPO / "deploy" / app / fname
        with open(dst, "w", encoding="utf-8", newline="\n") as fh:   # LF only — the node runs these under sh
            fh.write(body)
        print(f"wrote {dst.relative_to(REPO)}")


if __name__ == "__main__":
    main()
