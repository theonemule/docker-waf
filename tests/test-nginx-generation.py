#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"bin"))
import nginx_generation as g

class GenerationTests(unittest.TestCase):
    def test_publish_and_retire(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            a=root/("gen-"+"a"*32);b=root/("gen-"+"b"*32)
            for p in (a,b):p.mkdir();(p/"nginx.conf").write_text("configuration")
            g.activate(root,a)
            self.assertEqual(g.current(root),a)
            g.activate(root,b)
            self.assertEqual(g.current(root),b)
            # A still-live process protects its old generation.
            tick=Path(f"/proc/{os.getpid()}/stat").read_text().rsplit(")",1)[1].split()[19]
            g.retire(root,a,{str(os.getpid()):tick})
            g.prune(root)
            self.assertTrue(a.exists())
            g.retire(root,a,{str(os.getpid()):"0"})
            g.prune(root)
            self.assertFalse(a.exists());self.assertTrue(b.exists())
    def test_non_nginx_children_do_not_block_retirement(self):
        proc=subprocess.Popen(["sleep","10"])
        try:
            self.assertNotIn(str(proc.pid),g.workers(os.getpid()))
        finally:proc.terminate();proc.wait()
    def test_rewrite_only_managed_absolute_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/"test.conf"
            p.write_text('include /data/nginx/sites/*.conf;\nroot /data/www;\nreturn 302 https://example.test/data/nginx/path;\n')
            g.rewrite(p,[(Path("/data/nginx"),Path("/snapshot"))])
            self.assertEqual(p.read_text(),'include /snapshot/sites/*.conf;\nroot /data/www;\nreturn 302 https://example.test/data/nginx/path;\n')
    def test_startup_repairs_owned_volume_permissions_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/"owned"
            root.mkdir(mode=0o700)
            root.chmod(0o2770)
            g.secure_startup_root(root)
            self.assertEqual(root.stat().st_mode & 0o7777,0o700)
            link=Path(tmp)/"link"
            link.symlink_to(root,target_is_directory=True)
            with self.assertRaises(OSError):g.secure_startup_root(link)
            with patch.object(g.os,"geteuid",return_value=os.geteuid()+1):
                with self.assertRaisesRegex(ValueError,"owned by appliance"):g.secure_startup_root(root)

    def test_unsafe_pointer_and_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/"active.conf").symlink_to("/tmp/foreign")
            with self.assertRaises(ValueError):g.current(root)
            source=root/"source";source.mkdir()
            (source/"unsafe").symlink_to("/etc/passwd")
            with self.assertRaises(ValueError):g.copy_tree(source,root/"copy")
if __name__=="__main__":unittest.main(verbosity=2)
