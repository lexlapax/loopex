"""Harness-owned oracle for the M7 external task.

The maintainer-selected task: tools/threads.py's slugify transliterates
accented Latin letters to ASCII without changing any other output, and
`python3 tools/threads.py --check` still exits 0. M7_WORKSPACE names the
disposable checkout. Exit 0 passes; exit 2 reports every failed assertion.
"""
import importlib.util
import os
import subprocess
import sys

# The oracle never writes into the checkout it judges.
sys.dont_write_bytecode = True
workspace = os.environ["M7_WORKSPACE"]
source = os.path.join(workspace, "tools", "threads.py")
spec = importlib.util.spec_from_file_location("m7_external_threads", source)
threads = importlib.util.module_from_spec(spec)
spec.loader.exec_module(threads)

# Accented Latin letters transliterate; every other expected value is the
# base commit's own output and must not change.
cases = {
    "Café Society": "cafe-society",
    "Naïve Fixes": "naive-fixes",
    "Crème Brûlée": "creme-brulee",
    "Ångström Über Señor": "angstrom-uber-senor",
    "Survives Contact": "survives-contact",
    "  Hello, World!  ": "hello-world",
    "C3PO & R2-D2": "c3po-r2-d2",
    "already-slug": "already-slug",
    "日本 Notes": "notes",
    "": "",
}

failures = []
for name, expected in cases.items():
    actual = threads.slugify(name)
    if actual != expected:
        failures.append(f"slugify({name!r}) == {actual!r}, expected {expected!r}")

check = subprocess.run(
    [sys.executable, "-B", source, "--check"], cwd=workspace, capture_output=True, text=True
)
if check.returncode != 0:
    failures.append(f"tools/threads.py --check exited {check.returncode}: {check.stdout.strip()}")

for failure in failures:
    print("FAIL", failure)
if failures:
    sys.exit(2)
print(f"external oracle: {len(cases)} slugify cases and --check passed")
