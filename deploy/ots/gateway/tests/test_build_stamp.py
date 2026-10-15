"""C3B-C6: build-pyz.sh stamps the package's source hash into the pyz (log/healthz version), reproducibly."""
import hashlib
import pathlib
import subprocess
import zipfile

HERE = pathlib.Path(__file__).resolve().parents[1]


def build(out):
    subprocess.run(["sh", str(HERE / "build-pyz.sh"), str(out)], check=True, capture_output=True, timeout=120)
    return hashlib.sha256(out.read_bytes()).hexdigest()


def test_pyz_carries_a_source_stamp_and_is_reproducible(tmp_path):
    a = build(tmp_path / "a.pyz"); b = build(tmp_path / "b.pyz")
    assert a == b
    with zipfile.ZipFile(tmp_path / "a.pyz") as z:
        stamp = z.read("batman_eud_gateway/_build.py").decode()
    assert stamp.startswith('SOURCE = "') and len(stamp.strip()) == len('SOURCE = ""') + 12, stamp
    r = subprocess.run(["python3", "-c", "import sys; sys.path.insert(0, sys.argv[1]); import batman_eud_gateway as g; print(g.__version__)",
                        str(tmp_path / "a.pyz")], capture_output=True, text=True, timeout=60)
    assert r.stdout.strip().startswith("0.1.0+src."), r.stdout + r.stderr
