import hashlib
import importlib.util
import io
from pathlib import Path
import plistlib
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("pair", Path(__file__).resolve().parents[1] / "check-pair.py")
pair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pair)


class PairTests(unittest.TestCase):
    def test_metadata_and_missing_data(self):
        pin = pair.load_pins()["stable"]
        metadata = dict(tag_name=pin["tag"], prerelease=False, draft=False, assets=[dict(
            name="Libraries.tar.gz", digest="sha256:" + pin["sha256"], state="uploaded", browser_download_url=pair.asset_url(pin))])
        pair.check_metadata(pin, metadata)
        metadata["assets"][0]["digest"] = "sha256:" + "0" * 64
        with self.assertRaises(ValueError):
            pair.check_metadata(pin, metadata)
        with self.assertRaises(KeyError):
            pair.check_metadata(pin, {})

    def test_archive_digest_and_compatibility(self):
        pin = pair.load_pins()["stable"].copy()
        with tempfile.TemporaryDirectory(prefix="decant-pair-test-") as root:
            archive = Path(root) / "Libraries.tar.gz"
            def make_archive(version):
                info = dict(version=dict(zip(("major", "minor", "patch"), map(int, version.split(".")))),
                            dxmtVersion=pin["dxmt"], dxvkVersion=pin["dxvk"])
                files = {"Libraries/WhiskyWineVersion.plist": plistlib.dumps(info)}
                for name in ("wine64", "wineserver"):
                    files["Libraries/Wine/bin/" + name] = b"\xcf\xfa\xed\xfe" + b"\0" * 76
                for backend, dlls in (("DXMT", ("d3d11.dll", "dxgi.dll", "d3d10core.dll")),
                                      ("DXVK", ("d3d11.dll", "d3d10core.dll"))):
                    for arch in ("x64", "x32"):
                        for dll in dlls:
                            files[f"Libraries/{backend}/{arch}/{dll}"] = b"MZ" + b"\0" * 78
                with tarfile.open(archive, "w:gz") as tar:
                    for name, data in files.items():
                        member = tarfile.TarInfo(name)
                        member.size, member.mode = len(data), 0o755
                        tar.addfile(member, io.BytesIO(data))
                pin["sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
            make_archive(pin["version"])
            pair.check_archive(pin, archive)
            pin["sha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "digest"):
                pair.check_archive(pin, archive)
            make_archive("0.0.0")
            with self.assertRaisesRegex(ValueError, "version"):
                pair.check_archive(pin, archive)

    def test_vendor_mismatch_and_dirty(self):
        expected = pair.load_pins()["kitCommit"]
        with patch.object(pair.subprocess, "check_output", return_value="0" * 40):
            with self.assertRaisesRegex(ValueError, "HEAD"):
                pair.check_vendor(expected)
        with patch.object(pair.subprocess, "check_output", side_effect=[expected, " M tracked.swift"]):
            with self.assertRaisesRegex(ValueError, "dirty"):
                pair.check_vendor(expected)


if __name__ == "__main__":
    unittest.main()
