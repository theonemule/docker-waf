#!/usr/bin/env python3
"""Focused tests for signed shared file revisions, independent of NGINX."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"bin"))
import ha_config as ha

class SharedTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root=Path(self.tmp.name)
        self.shared=root/"shared"; self.shared.mkdir()
        self.a=root/"a"; self.a.mkdir()
        self.b=root/"b"; self.b.mkdir()
        for d in (self.a,self.b):
            (d/"sites").mkdir()
            (d/"certs/_admin").mkdir(parents=True)
            (d/"certs/_admin/local.pem").write_text(d.name)
            (d/"nginx").mkdir()
        (self.a/"sites/test.site").write_text("HOST=test.example.test\n")
        self.key="ab"*32
        (self.shared/"key").write_text(self.key)
        (self.shared/"cluster.json").write_text(json.dumps({"cluster_id":"test-ha","bootstrap_node":"node-a","members":{"node-a":"a","node-b":"b"}}))
        self.env=patch.dict(os.environ,{"LITEEDGE_HA_DIR":str(self.shared),"LITEEDGE_HA_KEY_FILE":str(self.shared/"key"),"LITEEDGE_HA_NODE_ID":"node-a","LITEEDGE_HA_BOOTSTRAP":"1"})
        self.env.start(); self.addCleanup(self.env.stop)
        def render(data,reload=True):
            (data/"nginx").mkdir(exist_ok=True)
            (data/"nginx/local-generated").write_text(data.name)
        self.render=patch.object(ha,"run_render",side_effect=render)
        self.render.start(); self.addCleanup(self.render.stop)

    def node(self,name):
        with patch.dict(os.environ,{"LITEEDGE_HA_NODE_ID":"node-"+name}):
            return ha.Shared(self.a if name=="a" else self.b)

    def bootstrap(self):
        a=self.node("a"); a.startup(); return a

    def test_shared_lock_timeout_and_reacquisition(self):
        path=self.shared/".writer.lock"
        with ha.file_lock(path):
            with self.assertRaisesRegex(ha.HAError, "Timed out acquiring"):
                with ha.shared_file_lock(path, timeout=0.05, interval=0.01):
                    self.fail("Acquired conflicting lock")
        with ha.shared_file_lock(path, timeout=0.1, interval=0.01) as fd:
            self.assertIsInstance(fd,int)

    def test_one_source_and_local_rendering(self):
        a=self.bootstrap()
        b=self.node("b"); b.startup()
        self.assertEqual((self.b/"sites/test.site").read_bytes(),(self.a/"sites/test.site").read_bytes())
        self.assertEqual((self.b/"certs/_admin/local.pem").read_text(),"b")
        self.assertEqual((self.b/"nginx/local-generated").read_text(),"b")
        self.assertFalse(b.publish())
        (self.b/"sites/test.site").write_text("HOST=updated.example.test\n")
        self.assertTrue(b.publish())
        self.assertTrue(a.sync(reload=False))
        self.assertEqual(a.local()["revision"],2)
        self.assertEqual((self.a/"sites/test.site").read_text(),"HOST=updated.example.test\n")

    def test_fs_group_inherited_setgid_does_not_change_capture(self):
        a=self.bootstrap()
        self.b.chmod(0o2770)
        b=self.node("b"); b.startup()
        self.assertTrue(b.local_matches())
        b.begin_write()
        self.assertFalse(b.publish())
        self.assertEqual(b.local()["revision"],1)

    def test_wrong_key_unknown_member_and_signature(self):
        a=self.bootstrap()
        (self.shared/"key").write_text("cd"*32)
        with self.assertRaises(ha.HAError): self.node("b").read()
        (self.shared/"key").write_text(self.key)
        with patch.dict(os.environ,{"LITEEDGE_HA_NODE_ID":"unknown"}):
            with self.assertRaises(ha.HAError): ha.Shared(self.b)
        m=json.loads((self.shared/"current.json").read_text()); m["writer"]="node-b"
        (self.shared/"current.json").write_text(json.dumps(m))
        with self.assertRaises(ha.HAError): a.read()

    def test_content_tampering_and_rollback(self):
        a=self.bootstrap()
        first=(self.shared/"current.json").read_bytes()
        (self.a/"sites/test.site").write_text("HOST=next.example.test\n")
        a.publish()
        last=(self.shared/"current.json").read_bytes()
        (self.shared/"current.json").write_bytes(first)
        with self.assertRaises(ha.HAError): a.sync(reload=False)
        (self.shared/"current.json").write_bytes(last)
        (a.directory(a.read())/"sites/test.site").write_text("tampered")
        with self.assertRaises(ha.HAError): self.node("b").startup()

    def test_no_accidental_bootstrap_or_reinitialization(self):
        with self.assertRaises(ha.HAError): self.node("b").startup()
        self.bootstrap()
        (self.shared/"current.json").unlink()
        (self.a/".liteedge-ha-applied.json").unlink()
        with self.assertRaises(ha.HAError): self.node("a").startup()

    def test_interrupted_write_recovers_same_revision(self):
        a=self.bootstrap()
        a.begin_write()
        (self.a/"sites/test.site").write_text("HOST=uncommitted.example.test\n")
        self.assertTrue(a.dirty.exists())
        self.assertTrue(a.sync(reload=False))
        self.assertEqual(a.local()["revision"],1)
        self.assertEqual((self.a/"sites/test.site").read_text(),"HOST=test.example.test\n")
        self.assertFalse(a.dirty.exists())

    def test_history_restore_and_retention(self):
        a=self.bootstrap()
        for i in range(2,5):
            (self.a/"sites/test.site").write_text(f"HOST=revision-{i}.example.test\n")
            a.publish()
        self.assertEqual([m["revision"] for m in a.history()],[1,2,3,4])
        self.assertEqual(a.restore_revision(2)["revision"],5)
        self.assertEqual((self.a/"sites/test.site").read_text(),"HOST=revision-2.example.test\n")
        self.assertEqual(a.prune(2),[1,2,3])
        self.assertEqual(len(a.history()),5)
        self.assertEqual(a.prune(2,apply=True),[1,2,3])
        self.assertEqual([m["revision"] for m in a.history()],[4,5])
        with self.assertRaises(ha.HAError): a.restore_revision(2)

    def test_restore_keeps_provider_revision_monotonic(self):
        a=self.bootstrap()
        (self.a/"sites/.provider-cluster-a.json").write_text(json.dumps({"revision":7,"digest":"old","hosts":[]}))
        a.publish()
        (self.a/"sites/.provider-cluster-a.json").write_text(json.dumps({"revision":8,"digest":"new","hosts":[]}))
        a.publish()
        a.restore_revision(2)
        state=json.loads((self.a/"sites/.provider-cluster-a.json").read_text())
        self.assertEqual(state,{"revision":9,"digest":"old","hosts":[]})
        a.restore_revision(1)
        state=json.loads((self.a/"sites/.provider-cluster-a.json").read_text())
        self.assertEqual(state["revision"],10)
        self.assertEqual(state["hosts"],[])

    def test_restore_refuses_provider_authorization_rollback(self):
        a=self.bootstrap()
        (self.a/"providers").mkdir()
        (self.a/"providers/cluster-a.json").write_text("{}")
        a.publish()
        with self.assertRaises(ha.HAError): a.restore_revision(1)
        self.assertEqual(a.local()["revision"],2)

    def test_render_failure_preserves_local_configuration(self):
        a=self.bootstrap()
        b=self.node("b"); b.startup()
        (self.a/"sites/test.site").write_text("HOST=changed.example.test\n")
        a.publish()
        with patch.object(ha,"run_render",side_effect=RuntimeError("render rejected")):
            with self.assertRaises(RuntimeError): b.sync(reload=False)
        self.assertEqual(b.local()["revision"],1)
        self.assertEqual((self.b/"sites/test.site").read_text(),"HOST=test.example.test\n")
        self.assertEqual((self.b/"nginx/local-generated").read_text(),"b")

if __name__=="__main__":
    unittest.main(verbosity=2)
