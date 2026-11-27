#!/usr/bin/env python3
"""Negative cases for the management form and archive trust boundary."""
import gzip
import io
import json
import random
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"bin"))
import admin_params
import archive_guard
import backupctl
import trusted_proxies
import ha_config

class SecurityInputs(unittest.TestCase):
    def test_proxy_trust(self):
        self.assertNotIn("set_real_ip_from", trusted_proxies.render(""))
        self.assertIn("set_real_ip_from 192.0.2.3/32;", trusted_proxies.render("192.0.2.3,2001:db8::/64"))
        for raw in ("0.0.0.0/0", "::/0", "192.0.2.3/24", "proxy.example", "127.0.0.1; include evil"):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                trusted_proxies.render(raw)

    def test_form_contract(self):
        self.assertEqual(admin_params.parse(b"host=web.test&text=a%26b%0A&label=a+b"),
                         {b"host":b"web.test",b"text":b"a&b\n",b"label":b"a b"})
        for raw in (b"host=a&host=b", b"host=a&%68ost=b", b"foo=%00", b"foo=%", b"foo=%GG",
                    b"foo\0=x", b"=x", b"bad[key]=x",
                    b"&".join(b"a%d=x"%i for i in range(257))):
            with self.subTest(raw=raw[:80]), self.assertRaises(ValueError):
                admin_params.parse(raw)

    def test_local_lock_contention_and_symlink(self):
        with tempfile.TemporaryDirectory() as work:
            lock = Path(work)/"lock"
            with ha_config.file_lock(lock):
                with self.assertRaises(ha_config.HAError):
                    with ha_config.file_lock(lock,timeout=0.02):
                        self.fail("lock was acquired despite contention")
            foreign=Path(work)/"foreign"
            foreign.write_text("untouched")
            link=Path(work)/"symlink"
            link.symlink_to(foreign)
            with self.assertRaises(OSError):
                with ha_config.file_lock(link):
                    self.fail("symlink lock accepted")
            self.assertEqual(foreign.read_text(),"untouched")

    def test_seeded_form_fuzz(self):
        rng = random.Random(20261126)
        for _ in range(3000):
            raw = bytes(rng.randrange(256) for _ in range(rng.randrange(128)))
            try:
                fields = admin_params.parse(raw)
            except ValueError:
                continue
            self.assertLessEqual(len(fields), admin_params.MAX_FIELDS)
            for key, value in fields.items():
                self.assertTrue(admin_params.KEY.fullmatch(key))
                self.assertNotIn(b"\0", value)

    def test_scan_gate(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("gate", Path(__file__).resolve().parents[1]/"scripts/security-scan-gate.py")
        gate = importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
        report = {"Results":[{"Target":"fixture","Secrets":[{"RuleID":"test"}],"Vulnerabilities":[
            {"Severity":"CRITICAL","FixedVersion":"2","VulnerabilityID":"CVE-test"},
            {"Severity":"HIGH","FixedVersion":"","VulnerabilityID":"CVE-unfixed"},
            {"Severity":"MEDIUM","FixedVersion":"2","VulnerabilityID":"CVE-medium"}]}]}
        self.assertEqual([x[1] for x in gate.findings(report)],["test","CVE-test"])

    def test_archives(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            source = root/"archive.tar.gz"
            def write(entries):
                with tarfile.open(source,"w:gz") as tar:
                    for name, kind, data in entries:
                        m = tarfile.TarInfo(name)
                        m.type = kind
                        if kind == tarfile.REGTYPE:
                            m.size=len(data)
                            tar.addfile(m,io.BytesIO(data))
                        else:
                            if kind == tarfile.SYMTYPE:m.linkname=data.decode()
                            tar.addfile(m)
            good = [("liteedge-bundle",tarfile.DIRTYPE,b""),
                    ("liteedge-bundle/manifest",tarfile.REGTYPE,b"FORMAT=example")]
            write(good)
            out = root/"good";out.mkdir()
            archive_guard.extract(source,out,"liteedge-bundle")
            self.assertEqual((out/"liteedge-bundle/manifest").read_bytes(),b"FORMAT=example")
            cases = [
                good+[("../escape",tarfile.REGTYPE,b"x")],
                good+[("liteedge-bundle/../escape",tarfile.REGTYPE,b"x")],
                good+[("liteedge-bundle/manifest",tarfile.REGTYPE,b"duplicate")],
                good+[("liteedge-bundle/link",tarfile.SYMTYPE,b"../../escape")],
                good+[("liteedge-bundle/device",tarfile.FIFOTYPE,b"")],
                good+[("liteedge-bundle/line\nbreak",tarfile.REGTYPE,b"x")],
                good+[("wrong/file",tarfile.REGTYPE,b"x")],
            ]
            for i, entries in enumerate(cases):
                write(entries)
                out=root/f"bad-{i}";out.mkdir()
                with self.subTest(i=i), self.assertRaises((archive_guard.ArchiveError,OSError)):
                    archive_guard.extract(source,out,"liteedge-bundle")
            write(good+[("liteedge-bundle/large",tarfile.REGTYPE,b"a"*32768)])
            out=root/"large";out.mkdir()
            with self.assertRaises(archive_guard.ArchiveError):
                archive_guard.extract(source,out,"liteedge-bundle",limit=16384)
            write(good)
            with gzip.open(source,"ab") as f:f.write(b"\0"*32768)
            out=root/"trailing";out.mkdir()
            with self.assertRaises(archive_guard.ArchiveError):
                archive_guard.extract(source,out,"liteedge-bundle",limit=16384)
            self.assertFalse((root/"escape").exists())

    def test_full_backup_streaming_roundtrip(self):
        with tempfile.TemporaryDirectory() as work:
            root=Path(work);data=root/"source";data.mkdir()
            for name in ("sites","certs","nginx","auth"):(data/name).mkdir()
            (data/"auth/.htpasswd").write_text("fixture-hash")
            (data/"sites/host.site").write_text("HOST=example.test\n")
            (data/"certs/link").symlink_to("../sites/host.site")
            source=root/"backup.tar.gz"
            backupctl.create(data,source)
            backupctl.stage_archive(source,root/"stage")
            self.assertEqual((root/"stage/data/sites/host.site").read_text(),"HOST=example.test\n")
            self.assertTrue((root/"stage/data/certs/link").is_symlink())

if __name__ == "__main__":
    unittest.main(verbosity=2)
