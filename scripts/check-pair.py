#!/usr/bin/env python3
"""Review gate; never installs, launches Wine, changes the checkout, or commits."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
PINS = ROOT / "Sources/decant/Resources/RuntimePins.json"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_pins(path=PINS):
    pins = json.loads(path.read_text())
    require(re.fullmatch(r"[0-9a-f]{40}", pins["kitCommit"]), "invalid kit commit")
    for channel in ("stable", "prerelease"):
        pin = pins[channel]
        require(re.fullmatch(r"v\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?", pin["tag"]), "invalid tag")
        require(re.fullmatch(r"\d+\.\d+\.\d+", pin["version"]), "invalid plist version")
        require(re.fullmatch(r"[0-9a-f]{64}", pin["sha256"]), "invalid digest")
        require(pin["prerelease"] is (channel == "prerelease"), "wrong channel")
        require(type(pin["gptkCapable"]) is bool and pin["dxmt"] and pin["dxvk"], "missing capabilities")
    return pins


def asset_url(pin):
    return f'https://github.com/frankea/Whisky/releases/download/{pin["tag"]}/Libraries.tar.gz'


def check_metadata(pin, metadata):
    assets = [a for a in metadata["assets"] if a["name"] == "Libraries.tar.gz"]
    require(metadata["tag_name"] == pin["tag"] and metadata["prerelease"] is pin["prerelease"]
            and metadata["draft"] is False, "release metadata mismatch")
    require(len(assets) == 1, "expected one runtime asset")
    asset = assets[0]
    require(asset["digest"] == "sha256:" + pin["sha256"] and asset["state"] == "uploaded"
            and asset["browser_download_url"] == asset_url(pin), "runtime asset metadata mismatch")


def check_vendor(expected, vendor=ROOT / "vendor/Whisky"):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(vendor), *args], text=True, timeout=30).strip()
    require(git("rev-parse", "HEAD") == expected, "vendor HEAD differs from reviewed kitCommit")
    require(not git("status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"), "dirty vendor; review it first")
    require((vendor / "WhiskyKit/Package.swift").is_file(), "missing WhiskyKit package")


def check_plist(pin, data):
    info = plistlib.loads(data)
    version = info["version"]
    require(".".join(str(version[k]) for k in ("major", "minor", "patch")) == pin["version"], "artifact version mismatch")
    require(info.get("gptkCapable", False) is pin["gptkCapable"]
            and info.get("dxmtVersion") == pin["dxmt"] and info.get("dxvkVersion") == pin["dxvk"], "artifact capabilities mismatch")


def normalized(name):
    path = PurePosixPath(name)
    require(not path.is_absolute() and ".." not in path.parts, "unexpected archive path")
    require(path.parts and path.parts[0] == "Libraries", "archive must contain only Libraries/")
    return str(path)


def link_target(member, name):
    # Normalize legitimate relative runtime links without following the host FS.
    target = PurePosixPath(member.linkname)
    require(not target.is_absolute(), "absolute archive link")
    parts = list(PurePosixPath(name).parent.parts) if member.issym() else []
    for part in target.parts:
        if part == "..":
            require(len(parts) > 1, "archive link leaves Libraries/")
            parts.pop()
        elif part != ".":
            parts.append(part)
    require(parts and parts[0] == "Libraries", "archive link leaves Libraries/")
    return "/".join(parts)


def check_archive(pin, archive):
    digest = hashlib.sha256()
    with open(archive, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    require(digest.hexdigest() == pin["sha256"], "bad archive digest")
    entries, links, heads = {}, {}, {}
    with tarfile.open(archive, "r|gz") as tar:
        for member in tar:
            name = normalized(member.name)
            require(name not in entries, "duplicate archive path")
            require(member.isfile() or member.isdir() or member.issym() or member.islnk(), "special archive entry")
            entries[name] = member
            if member.issym() or member.islnk():
                links[name] = link_target(member, name)
            elif member.isfile():
                stream = tar.extractfile(member)
                if name == "Libraries/WhiskyWineVersion.plist":
                    require(member.size <= 65536, "oversized runtime plist")
                    check_plist(pin, stream.read())
                heads[name] = stream.read(80)
    require("Libraries/WhiskyWineVersion.plist" in heads, "missing runtime plist")

    def file_head(name):
        seen = set()
        while name in links:
            require(name not in seen, "cyclic runtime link")
            seen.add(name)
            name = links[name]
        require(name in heads, f"missing runtime file: {name}")
        return heads[name], entries[name]

    for name in ("wine64", "wineserver"):
        head, member = file_head("Libraries/Wine/bin/" + name)
        require(member.mode & 0o111 and head[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe"), "Wine binary not executable Mach-O")
    for arch in ("x64", "x32"):
        for dll in ("d3d11.dll", "dxgi.dll", "d3d10core.dll"):
            head, _ = file_head(f"Libraries/DXMT/{arch}/{dll}")
            require(len(head) >= 80 and head[:2] == b"MZ" and head[64:80] != b"Wine builtin DLL", "DXMT must be native PE")
        for dll in ("d3d11.dll", "d3d10core.dll"):
            head, _ = file_head(f"Libraries/DXVK/{arch}/{dll}")
            require(head[:2] == b"MZ", "missing DXVK PE payload")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", choices=("stable", "prerelease"), required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--archive", type=Path, help="already downloaded Libraries.tar.gz (never downloaded here)")
    source.add_argument("--metadata-only", action="store_true", help="preflight only, NOT a completed artifact review")
    args = parser.parse_args()
    pins = load_pins()
    check_vendor(pins["kitCommit"])
    pin = pins[args.channel]
    request = urllib.request.Request(f'https://api.github.com/repos/frankea/Whisky/releases/tags/{pin["tag"]}', headers={"User-Agent": "decant-pair-check"})
    with urllib.request.urlopen(request, timeout=30) as response:
        check_metadata(pin, json.load(response))
    if args.archive:
        check_archive(pin, args.archive)
        print("archive digest, layout, plist capabilities, Wine binaries and 32/64-bit backend payloads checked", flush=True)
    env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
    # Optional Apple validation is a separate opt-in read-only check, not needed
    # to run this deterministic non-Wine pair gate.
    env.pop("DECANT_TEST_GPTK_PATH", None)
    subprocess.run(["python3", "-m", "unittest", "discover", "-s", "scripts/tests"], cwd=ROOT, env=env, check=True, timeout=120)
    subprocess.run(["swift", "test", "--build-system", "native", "--jobs", "4"], cwd=ROOT, env=env, check=True, timeout=600)
    subprocess.run(["swift", "build", "--build-system", "native", "-c", "release", "--jobs", "4"], cwd=ROOT, env=env, check=True, timeout=600)
    check_vendor(pins["kitCommit"])
    require(load_pins() == pins, "pins changed during checks")
    print("PAIR CHECK PASSED (static compatibility only; Wine integration still required)" if args.archive else "METADATA PREFLIGHT PASSED; artifact digest/layout not checked")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, tarfile.TarError) as error:
        raise SystemExit(f"pair check failed: {error}")
