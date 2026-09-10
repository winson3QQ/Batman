"""Patch FreeTAKServer 2.2.1 in the build image (see deploy/fts/Dockerfile, #44).

1. Fix digitalpy tracing: construct BatchSpanProcessor(exporter) directly, bypassing
   the DI setattr that breaks on opentelemetry>=1.x (span_exporter became read-only).
2. Relocate ports off openmanetd (which owns 8087/8080 on the node):
   CoTServicePort 8087->18087, HTTPTakAPIPort 8080->18080.
"""
import sys

SP = "/usr/local/lib/python3.11/site-packages"

tp = f"{SP}/digitalpy/core/telemetry/impl/opentel_tracing_provider.py"
s = open(tp).read()
old = 'self.processor = ObjectFactory.get_new_instance("TracerProcessor", dynamic_configuration={"span_exporter": exporter})'
new = ('from opentelemetry.sdk.trace.export import BatchSpanProcessor as _BSP\n'
       '        self.processor = _BSP(exporter)')
if old not in s:
    print("ERROR: tracing target line not found", file=sys.stderr); sys.exit(1)
open(tp, "w").write(s.replace(old, new))
print("patched: tracing provider")

mc = f"{SP}/FreeTAKServer/core/configuration/MainConfig.py"
s = open(mc).read()
repls = [
    ('"CoTServicePort": {"default": 8087, "type": int},',
     '"CoTServicePort": {"default": 18087, "type": int},'),
    ('"HTTPTakAPIPort": {"default": 8080, "type": int},',
     '"HTTPTakAPIPort": {"default": 18080, "type": int},'),
]
for o, n in repls:
    if o not in s:
        print(f"ERROR: MainConfig target not found: {o}", file=sys.stderr); sys.exit(1)
    s = s.replace(o, n)
open(mc, "w").write(s)
print("patched: CoT 8087->18087, HTTPTakAPI 8080->18080")
