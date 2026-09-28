import sys, os, re, collections
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gen"))
import layout as L
ses = sys.argv[1] if len(sys.argv) > 1 else os.path.join(L.OUT, "route", "batman-hat-inc.ses")
print(L.finish(ses, replace=True))
txt = open(os.path.join(L.OUT, "route", "drc.txt")).read()
for l in txt.splitlines():
    if l.startswith("** Found"):
        print(l)
print({k: v for k, v in collections.Counter(re.findall(r"^\[(\w+)\]", txt, re.M)).items() if not k.startswith(("silk", "lib_"))})
