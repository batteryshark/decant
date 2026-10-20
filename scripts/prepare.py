#!/usr/bin/env python3
"""GPL-3.0: single checked, reversible preparation for every decant build."""
from contextlib import contextmanager
import hashlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shutil
import re
import struct
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
ENV = dict(os.environ, DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
ENV.pop('DECANT_TEST_GPTK_PATH', None)

def require(ok, message):
    if not ok:
        raise ValueError(message)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(args, cwd=ROOT, timeout=600):
    subprocess.run(args, cwd=cwd, env=ENV, check=True, timeout=timeout)

def swift(action, *args, cwd=ROOT):
    run(['swift', action, '--build-system', 'native', '--jobs', '4', *args], cwd=cwd)
    pins_path = cwd / 'Sources/decant/Resources/RuntimePins.json'
    if pins_path.exists():
        configuration = args[args.index('-c')+1] if '-c' in args else 'debug'
        check_bundle(cwd / '.build' / configuration / 'decant_decant.bundle', pins_path)

def check_bundle(bundle, pins_path):
    pins = json.loads(pins_path.read_text())
    require((bundle / 'RuntimePins.json').read_bytes() == pins_path.read_bytes(), 'packaged pins mismatch')
    require(digest(bundle / pins['shim']['file']) == pins['shim']['sha256'], 'packaged shim mismatch')

def check_pe(data, definition):
    def u(fmt, offset):
        require(0 <= offset <= len(data) - struct.calcsize(fmt), 'PE bounds')
        return struct.unpack_from(fmt, data, offset)
    require(data[:2] == b'MZ', 'MZ header')
    pe, = u('<I', 60)
    require(pe >= 96 and data[pe:pe+4] == b'PE\0\0', 'PE header')
    machine, sections = u('<HH', pe+4)
    optsize, flags = u('<HH', pe+20)
    opt = pe+24
    require(machine == 0x8664 and flags & 0x2000 and not flags & 1, 'AMD64 DLL/relocations')
    require(optsize >= 160 and u('<H', opt)[0] == 0x20b, 'PE32+')
    require(u('<Q', opt+24)[0] == 0x180000000 and u('<H', opt+70)[0] & 0x40, 'image base/ASLR')
    ranges = []
    for i in range(sections):
        _, rva, size, raw = u('<IIII', opt+optsize+40*i+8)
        require(raw+size <= len(data), 'section bounds')
        ranges.append((rva, size, raw))
    def address(rva, size=1):
        for start, length, raw in ranges:
            if start <= rva and rva+size <= start+length:
                return raw+rva-start
        raise ValueError('RVA bounds')
    reloc, relocsize = u('<II', opt+152)
    require(relocsize > 0, 'relocations missing')
    address(reloc, relocsize)
    export, size = u('<II', opt+112)
    base, count, names, funcs, strings, ordinals = u('<IIIIII', address(export, 40)+16)
    expected = {int(n): name for name, n in re.findall(r'^(\w+)\s*=\s*\w+\s+@(\d+)', definition, re.M)}
    require(base == 100 and count == names == 12, 'export count')
    actual = {}
    for i in range(names):
        ordinal = u('<H', address(ordinals+2*i, 2))[0]
        require(ordinal < count, 'ordinal bounds')
        function = u('<I', address(funcs+4*ordinal, 4))[0]
        require(not export <= function < export+size, 'unexpected forwarded export')
        address(function)
        rva = u('<I', address(strings+4*i, 4))[0]
        text = bytearray()
        for j in range(256):
            char = data[address(rva+j)]
            if not char:
                break
            text.append(char)
        else:
            raise ValueError('unterminated export name')
        actual[base+ordinal] = text.decode('ascii')
    require(actual == expected, 'exact export names/ordinals')

def resource(pins):
    pin = pins['shim']
    require(re.fullmatch('[0-9a-f]{40}', pin['commit']), 'invalid source commit')
    cache = ROOT / '.build/production-shim-preflight'
    source = cache / 'gptk-video'
    source.mkdir(parents=True, exist_ok=True)
    for name, expected in pin['sources'].items():
        path = source / name
        if not path.exists():
            url = f"https://raw.githubusercontent.com/{pin['repository']}/{pin['commit']}/gptk-video/{name}"
            data = urllib.request.urlopen(url, timeout=30).read()
            require(hashlib.sha256(data).hexdigest() == expected, f'source identity: {name}')
            path.write_bytes(data)
        require(digest(path) == expected, f'cached source identity: {name}')
    output = cache / pin['file']
    if not output.exists():
        compiler = shutil.which(pin['compiler'])
        require(compiler and digest(Path(compiler)) == pin['compilerSHA256'], 'compiler identity mismatch')
        version = subprocess.check_output([compiler, '-dumpfullversion'], text=True, timeout=10).strip()
        require(version == pin['compilerVersion'], 'compiler version mismatch')
        mingw = subprocess.check_output(['brew', 'list', '--versions', 'mingw-w64'], text=True, timeout=30).strip()
        require(mingw == 'mingw-w64 ' + pin['mingw'], 'mingw identity mismatch')
        run([compiler, '-shared', '-O2', '-fno-strict-aliasing', '-Wl,--no-insert-timestamp',
             '-Wl,--image-base,0x180000000', '-I', 'gptk-video', 'gptk-video/d3d12shim-4.0b3.c',
             'gptk-video/d3d12shim-4.0b3.def', '-luuid', '-ldxguid', '-o', pin['file']], cwd=cache, timeout=180)
        data = bytearray(output.read_bytes())
        check_pe(data, (source / 'd3d12shim-4.0b3.def').read_text())
        require(len(data) >= 96 and data[:2] == b'MZ', 'invalid DOS header')
        pe = struct.unpack_from('<I', data, 0x3c)[0]
        require(96 <= pe <= len(data)-24 and data[pe:pe+4] == b'PE\0\0', 'invalid PE bounds')
        data[64:96] = b'Wine builtin DLL' + bytes(16)
        output.write_bytes(data)
    require(output.stat().st_size == pin['size'] and digest(output) == pin['sha256'], 'shim artifact mismatch')
    check_pe(output.read_bytes(), (source / 'd3d12shim-4.0b3.def').read_text())
    require(output.read_bytes()[64:96] == b'Wine builtin DLL' + bytes(16), 'builtin marker')
    target = ROOT / 'Sources/decant/Resources' / pin['file']
    if target.exists():
        require(digest(target) == pin['sha256'], 'generated resource mismatch')
    else:
        shutil.copy2(output, target)

@contextmanager
def prepared():
    (ROOT / '.build').mkdir(exist_ok=True)
    with (ROOT / '.build/decant-preparation.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with _prepared() as pins:
            yield pins

@contextmanager
def _prepared():
    spec = importlib.util.spec_from_file_location('pair', ROOT / 'scripts/check-pair.py')
    pair = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pair)
    pins = pair.load_pins()
    pair.check_vendor(pins['kitCommit'])
    patch = ROOT / pins['kitPatch']['path']
    require(digest(patch) == pins['kitPatch']['sha256'], 'kit patch identity mismatch')
    resource(pins)
    vendor = ROOT / 'vendor/Whisky'
    run(['git', 'apply', '--check', str(patch)], cwd=vendor, timeout=30)
    run(['git', 'apply', str(patch)], cwd=vendor, timeout=30)
    try:
        yield pins
    finally:
        # Reverse only our exact patch. Never reset, clean or discard another edit.
        run(['git', 'apply', '--reverse', '--check', str(patch)], cwd=vendor, timeout=30)
        run(['git', 'apply', '--reverse', str(patch)], cwd=vendor, timeout=30)
        pair.check_vendor(pins['kitCommit'])

if __name__ == '__main__':
    import sys
    with prepared():
        swift('build', *sys.argv[1:])
