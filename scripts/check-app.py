#!/usr/bin/env python3
"""Package-only signed wrapper regression; never install/register/launch Wine.

Pass an already checked build directory (including both executables) and the
expected embedded CLI ID. Outputs stay in a new private temporary directory.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from prepare import ROOT, check_bundle

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-dir', type=Path, required=True)
parser.add_argument('--bundle-id', required=True)
args = parser.parse_args()
build = args.build_dir.resolve()
parent = Path(tempfile.mkdtemp(prefix='decant-signed-app-'))
app = parent / 'Decant.app'

def run(command, success=True):
    result = subprocess.run([str(x) for x in command], capture_output=True, text=True, timeout=60)
    assert (result.returncode == 0) == success, (command, result.returncode, result.stdout, result.stderr)
    return result.stdout

run(['sh', ROOT / 'scripts/install-app.sh', '--package-only', build, app])
run(['codesign', '--verify', '--strict', '--verbose=2', app])
cli = app / 'Contents/Helpers/decant'
bundle = app / 'Contents/Resources/decant_decant.bundle'
assert not (cli.parent / bundle.name).exists()
check_bundle(bundle, ROOT / 'Sources/decant/Resources/RuntimePins.json')
paths = json.loads(run([cli, 'runtime', 'paths']))
assert paths['bundleID'] == args.bundle_id, paths
assert Path(paths['support']) == Path.home() / 'Library/Application Support' / args.bundle_id
assert Path(paths['bottles']) == Path(paths['support']) / 'Bottles'
assert Path(paths['logs']) == Path.home() / 'Library/Logs' / args.bundle_id
pins = json.loads((bundle / 'RuntimePins.json').read_text())
status = run([cli, 'runtime', 'status', '--prerelease'])
assert pins['prerelease']['tag'] in status and pins['shim']['sha256'] in status
# The original build bundle remains present: absence here MUST NOT fall back.
hidden = bundle.with_name('hidden-resources')
bundle.rename(hidden)
missing = subprocess.run([cli, 'runtime', 'status'], capture_output=True, text=True, timeout=15)
assert missing.returncode == 1 and 'bundled runtime pins missing' in missing.stderr, missing
hidden.rename(bundle)
pin_path = bundle / 'RuntimePins.json'
original = pin_path.read_bytes()
pin_path.write_bytes(b'damaged')
run([cli, 'runtime', 'status'], success=False)
pin_path.write_bytes(original)
# Standalone CLI still uses the adjacent layout, independently of app metadata.
standalone = parent / 'standalone'
standalone.mkdir()
shutil.copy2(cli, standalone / 'decant')
shutil.copytree(bundle, standalone / bundle.name)
assert pins['prerelease']['tag'] in run([standalone / 'decant', 'runtime', 'status'])
run(['codesign', '--verify', '--strict', app])
(parent / 'result.json').write_text(json.dumps(dict(paths=paths, app=str(app), status=status,
    signing='strict PASS', relocated='PASS', missingAndDamagedPins='normal failure PASS',
    standalone='PASS'), indent=2))
print(parent)
print('PASS signed wrapper, relocated checked resources, standalone, missing/damaged pins')
