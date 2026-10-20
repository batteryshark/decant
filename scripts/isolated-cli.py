#!/usr/bin/env python3
"""Build a uniquely identified integration CLI; never install or run Wine."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parent.parent
pins = json.loads((root / "Sources/decant/Resources/RuntimePins.json").read_text())
vendor = root / "vendor/Whisky"
assert subprocess.check_output(["git", "-C", vendor, "rev-parse", "HEAD"], text=True, timeout=30).strip() == pins["kitCommit"], "kit mismatch"
assert not subprocess.check_output(["git", "-C", vendor, "status", "--porcelain", "--untracked-files=all"], text=True, timeout=30).strip(), "dirty vendor"
parent = Path(tempfile.mkdtemp(prefix="decant-integration-"))
copy = parent / "launcher"
copy.mkdir()
for name in ("Package.swift", "Package.resolved", "Sources", "Resources", "UnitTests"):
    source, target = root / name, copy / name
    if source.is_dir():
        shutil.copytree(source, target)
    else:
        shutil.copy2(source, target)
shutil.copytree(root / "vendor/Whisky/WhiskyKit", copy / "vendor/Whisky/WhiskyKit",
                ignore=shutil.ignore_patterns(".build", ".git", ".swiftpm"))
identifier = "io.github.batteryshark.decant.integration." + uuid.uuid4().hex
plist_path = copy / "Resources/Info.plist"
info = plistlib.loads(plist_path.read_bytes())
info["CFBundleIdentifier"] = identifier
plist_path.write_bytes(plistlib.dumps(info))
env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
subprocess.run(["swift", "build", "--build-system", "native", "--jobs", "4"], cwd=copy, env=env, check=True, timeout=600)
binary = copy / ".build/debug/decant"
paths = json.loads(subprocess.check_output([binary, "runtime", "paths"], env=env, text=True, timeout=15))
assert paths["bundleID"] == identifier, "embedded bundle ID not honored"
assert Path(paths["support"]).name == identifier, "Foundation support path not isolated"
assert Path(paths["bottles"]).parent == Path(paths["support"]), "bottle root not isolated"
assert Path(paths["logs"]).name == identifier, "log path not isolated"
assert not Path(paths["support"]).exists(), "unique test root unexpectedly exists"
# Also prove the CLI can find its pin resource when relocated away from the
# package, as the Finder helper is. This is a local status read only.
relocated = parent / "relocated"
relocated.mkdir()
shutil.copy2(binary, relocated / "decant")
shutil.copytree(copy / ".build/debug/decant_decant.bundle", relocated / "decant_decant.bundle")
status = subprocess.check_output([relocated / "decant", "runtime", "status", "--prerelease"], env=env, text=True, timeout=15)
assert "installed: none" in status and pins["prerelease"]["tag"] in status, "isolated local status failed"
assert not Path(paths["support"]).exists(), "local status unexpectedly wrote application data"
report = dict(paths, binary=str(binary), package=str(copy))
(parent / "isolation.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
print(status)
print("Built only. Use ONLY this binary for authorized integration; HOME was not changed.")
