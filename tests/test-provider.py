#!/usr/bin/env python3
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"bin"))
import unittest
import io
import subprocess
from unittest.mock import patch
import provider_admin as pa

spec = importlib.util.spec_from_file_location("providerctl", Path(__file__).resolve().parents[1]/"bin/providerctl.py")
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)

class ProviderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name)
        for name in ("sites","certs","nginx","providers"):
            (self.data/name).mkdir()
        self.policy = {"host_suffixes":["apps.example.test"],"backend_cidrs":["10.96.0.0/12"],"min_waf_pl":2}
        self.payload = {"revision":0,"sites":[{"host":"web.apps.example.test","routes":[{"match":"prefix","path":"/foo","target":"http://10.96.0.5:8080"}]}]}
        self.calls = []
        (self.data/"sites/manual.site").write_text("HOST=manual.example.test\nALIASES=\n")
        (self.data/"certs/manual.example.test").mkdir()
        (self.data/"certs/manual.example.test/privkey.pem").write_text("manual-key")
    def render(self, data):
        self.calls.append("render")
        (data/"nginx/generated").write_text("rendered")
        return set()
    def reload(self, data):
        self.calls.append("reload")
    def apply(self, payload=None, render=None):
        return p.apply(self.data,"cluster-a",payload or self.payload,self.policy,render or self.render,self.reload)
    def test_grpc_scope_validation_and_record(self):
        payload=copy.deepcopy(self.payload)
        route=payload["sites"][0]["routes"][0]
        route.update(grpc=True,method="POST")
        with self.assertRaises(p.Error) as exc:p.normalize(payload,self.policy)
        self.assertEqual(exc.exception.status,403)
        policy={**self.policy,"allow_grpc":True}
        n=p.normalize(payload,policy)
        self.assertTrue(n[0]["routes"][0]["grpc"])
        p.materialize(self.data,"cluster-a",n,set())
        for path in (self.data/"sites/web.apps.example.test.routes").glob("*.route"):
            self.assertTrue(p.features.from_record(p.kv(path),True)["grpc"])
        for field,value in [("method","GET"),("deadlines",{"request_ms":1000}),("retry",{"attempts":0}),("grpc","true"),("query_matches",[{"name":"a","value":"b"}])]:
            bad=copy.deepcopy(payload);bad["sites"][0]["routes"][0][field]=value
            with self.subTest(field=field),self.assertRaises(p.Error):p.normalize(bad,policy)

    def test_transport_scope_revision_ownership_and_repair(self):
        with patch.dict("os.environ",{"LITEEDGE_EXTRA_TCP_PORTS":"9000:19000","LITEEDGE_EXTRA_UDP_PORTS":"9001:19001","LITEEDGE_EXTRA_TLS_PORTS":"9444:19444"},clear=False):
            payload=copy.deepcopy(self.payload)
            payload["streams"]=[
              {"protocol":"tcp","port":9000,"backends":[{"target":"tcp://10.96.0.5:12001","weight":1}]},
              {"protocol":"udp","port":9001,"backends":[{"target":"udp://10.96.0.5:12002","weight":2}]},
              {"protocol":"tls","port":9444,"hostname":"web.apps.example.test","backends":[{"target":"tcp://10.96.0.5:12003","weight":1}]},
            ]
            policy={**self.policy,"allow_stream":True,"stream_ports":{"tcp":[9000],"udp":[9001],"tls":[9444]}}
            with self.assertRaises(p.Error) as exc:p.validate(self.data,"cluster-a",payload,self.policy)
            self.assertEqual(exc.exception.status,403)
            self.assertEqual(exc.exception.location["stream_index"],0)
            result=p.apply(self.data,"cluster-a",payload,policy,self.render,self.reload)
            self.assertEqual(result["revision"],1)
            self.assertEqual(len(result["streams"]),3)
            self.assertIn("ssl_preread on",p.streams.render(self.data))
            self.assertIn("udp reuseport",p.streams.render(self.data))
            self.assertEqual(len(pa.inventory(self.data,"cluster-a")[1]),4)
            payload["revision"]=1
            self.assertFalse(p.apply(self.data,"cluster-a",payload,policy,self.render,self.reload)["changed"])
            p.streams.file(self.data,"cluster-a").write_text("bad json")
            self.assertTrue(p.apply(self.data,"cluster-a",payload,policy,self.render,self.reload)["changed"])
            payload["revision"]=2
            for field,value in [("port",9443),("protocol","udp"),("backends",[{"target":"tcp://192.0.2.1:22","weight":1}])]:
                bad=copy.deepcopy(payload);bad["streams"][0][field]=value
                with self.subTest(field=field),self.assertRaises(p.Error):p.validate(self.data,"cluster-a",bad,policy)
            other={"revision":0,"sites":[],"streams":[payload["streams"][0]]}
            with self.assertRaises(p.Error) as exc:p.validate(self.data,"cluster-b",other,policy)
            self.assertEqual(exc.exception.status,403)
            # Denied provider or native port collision must never modify traffic.
            with self.assertRaises(PermissionError):p.streams.check_ownership(self.data,p.streams.NATIVE,other["streams"])
            changed=copy.deepcopy(payload);changed["streams"]=[]
            def fail(d):raise RuntimeError("render failure")
            with self.assertRaises(p.Error):p.apply(self.data,"cluster-a",changed,policy,fail,self.reload)
            self.assertEqual(len(p.streams.inventory(self.data)["cluster-a"]),3)
            self.assertEqual(p.state(self.data,"cluster-a")["revision"],2)
            self.assertTrue(p.apply(self.data,"cluster-a",changed,policy,self.render,self.reload)["changed"])
            self.assertNotIn("cluster-a",p.streams.inventory(self.data))

    def test_mirror_scope_and_validation(self):
        desired=copy.deepcopy(self.payload)
        route=desired["sites"][0]["routes"][0]
        route["mirrors"]=["http://10.96.0.6:8080"]
        with self.assertRaises(p.Error) as exc:p.normalize(desired,self.policy)
        self.assertEqual(exc.exception.status,403)
        policy={**self.policy,"allow_request_mirroring":True}
        normalized=p.normalize(desired,policy)
        self.assertEqual(normalized[0]["routes"][0]["mirrors"],[{"target":route["mirrors"][0],"basis_points":10000}])
        for bad in (["http://192.0.2.1:80"],["http://10.96.0.6:8080/path"],["http://10.96.0.6:8080"]*2):
            route["mirrors"]=bad
            with self.subTest(bad=bad),self.assertRaises(p.Error):p.normalize(desired,policy)
        route["mirrors"]=["http://10.96.0.6:8080"]
        route["rewrite"]={"hostname":"web.apps.example.test"}
        with self.assertRaises(p.Error):p.normalize(desired,policy)

    def test_extra_http_ports_scope_and_materialization(self):
        payload=copy.deepcopy(self.payload)
        site=payload["sites"][0]
        site["listeners"]=["http","http:8080"]
        site["routes"][0]["schemes"]=["http"]
        extra=copy.deepcopy(site["routes"][0])
        extra.update(schemes=["http:8080"],target="http://10.96.0.6:8080")
        site["routes"].append(extra)
        policy={**self.policy,"extra_http_ports":[8080]}
        with patch.dict("os.environ",{"LITEEDGE_EXTRA_HTTP_PORTS":"8080:18080"}):
            with self.assertRaises(p.Error) as denied:p.normalize(payload,self.policy)
            self.assertEqual(denied.exception.status,403)
            normalized=p.normalize(payload,policy)
            p.materialize(self.data,"cluster-a",normalized,set())
            self.assertEqual(p.kv(self.data/"sites/web.apps.example.test.site")["GW_LISTENERS"],"http,http:8080")
            records=[p.kv(f) for f in (self.data/"sites/web.apps.example.test.routes").glob("*.route")]
            self.assertEqual({(r["SCHEMES"],r["TARGET"]) for r in records},{("http","http://10.96.0.5:8080"),("http:8080","http://10.96.0.6:8080")})
            for bad in ["http:9443","http:08080","http:65536","https:8080","http:8080;"]:
                broken=copy.deepcopy(payload)
                broken["sites"][0]["listeners"]=["http",bad]
                with self.subTest(bad=bad),self.assertRaises(p.Error):p.normalize(broken,policy)
        with patch.dict("os.environ",{"LITEEDGE_EXTRA_HTTP_PORTS":""}):
            with self.assertRaises(p.Error):p.normalize(payload,policy)
        for value in ("8080:9443","8080:8080","8080:80","9443:18080","80:18080","8080:18080,8090:18080"):
            with self.subTest(mapping=value),patch.dict("os.environ",{"LITEEDGE_EXTRA_HTTP_PORTS":value,"LITEEDGE_HTTP_PORT":"8080"}):
                with self.assertRaises(ValueError):p.ports.mappings()

    def test_extra_https_ports_certificate_isolation(self):
        host=self.payload["sites"][0]["host"]
        cert,key=self.data/"cert.pem",self.data/"key.pem"
        subprocess.run(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-days","1","-keyout",str(key),"-out",str(cert),"-subj","/CN="+host,"-addext","subjectAltName=DNS:"+host],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        tls={"certificate":cert.read_text(),"private_key":key.read_text()}
        desired=copy.deepcopy(self.payload)
        site=desired["sites"][0]
        site.update(listeners=["http","https:8443","https:8444"],tls_listeners={"https:8443":tls,"https:8444":None})
        site["routes"][0]["schemes"]=["https:8443"]
        policy={**self.policy,"extra_https_ports":[8443,8444]}
        with patch.dict("os.environ",{"LITEEDGE_EXTRA_HTTPS_PORTS":"8443:18443,8444:18444"}):
            with self.assertRaises(p.Error):p.normalize(desired,self.policy)
            n=p.normalize(desired,policy)
            p.materialize(self.data,"cluster-a",n,set())
            self.assertEqual(p.kv(self.data/"sites"/(host+".site"))["GW_TLS_REJECT_LISTENERS"],"https:8444")
            self.assertEqual((self.data/"certs"/host/"listeners/https-8443/fullchain.pem").read_text(),tls["certificate"])
            self.assertFalse((self.data/"certs"/host/"fullchain.pem").exists())
            for change in ("missing","reject","unprovisioned","wrong-kind"):
                bad=copy.deepcopy(desired)
                x=bad["sites"][0]
                if change=="missing":del x["tls_listeners"]["https:8443"]
                elif change=="reject":x["tls_listeners"]["https:8443"]=None
                elif change=="unprovisioned":x["listeners"].append("https:8445")
                else:x["tls_listeners"]["http:8443"]=tls
                with self.subTest(change=change),self.assertRaises(p.Error):p.normalize(bad,policy)
            with self.assertRaises(p.Error):p.normalize(desired,{**policy,"extra_http_ports":[8443]})
        with patch.dict("os.environ",{"LITEEDGE_EXTRA_HTTP_PORTS":"8080:18443","LITEEDGE_EXTRA_HTTPS_PORTS":"8443:18443"}):
            with self.assertRaises(ValueError):p.ports.mappings()

    def test_retry_policy_scope_and_validation(self):
        payload=copy.deepcopy(self.payload)
        route=payload["sites"][0]["routes"][0]
        del route["target"]
        route["backends"]=[{"target":"http://10.96.0.5:8080","weight":1},{"target":"http://10.96.0.6:8080","weight":1}]
        route["retry"]={"attempts":1,"codes":[503],"budget_ms":250}
        with self.assertRaises(p.Error) as exc:p.normalize(payload,self.policy)
        self.assertEqual(exc.exception.status,403)
        policy={**self.policy,"allow_backend_retries":True}
        self.assertEqual(p.normalize(payload,policy)[0]["routes"][0]["retry"],route["retry"])
        for bad in ({"attempts":5},{"attempts":1,"codes":[200]},{"attempts":0,"codes":[503]},{"attempts":1,"budget_ms":60001},{"attempts":True}):
            route["retry"]=bad
            with self.subTest(bad=bad),self.assertRaises(p.Error):p.normalize(payload,policy)
        route["retry"]={"attempts":1,"codes":[500]}
        route["backends"][1]["target"]="invalid"
        with self.assertRaises(p.Error):p.normalize(payload,policy)
        route["retry"]={"attempts":0}
        self.assertEqual(p.normalize(payload,self.policy)[0]["routes"][0]["retry"]["attempts"],0)

    def test_deadline_policy_scope_and_validation(self):
        desired=copy.deepcopy(self.payload)
        route=desired["sites"][0]["routes"][0]
        route["deadlines"]={"request_ms":1000,"backend_ms":250}
        with self.assertRaises(p.Error) as exc:p.normalize(desired,self.policy)
        self.assertEqual(exc.exception.status,403)
        policy={**self.policy,"allow_request_deadlines":True,"allow_backend_retries":True}
        route["retry"]={"attempts":1,"backoff_ms":100}
        normalized=p.normalize(desired,policy)[0]["routes"][0]
        self.assertEqual(normalized["deadlines"],route["deadlines"])
        self.assertEqual(normalized["retry"]["backoff_ms"],100)
        for bad in ({},{"request_ms":True},{"request_ms":-1},{"request_ms":3600001},{"request_ms":100,"backend_ms":101}):
            route["deadlines"]=bad
            with self.subTest(bad=bad),self.assertRaises(p.Error):p.normalize(desired,policy)
        route["deadlines"]={"request_ms":0}
        self.assertEqual(p.normalize(desired,policy)[0]["routes"][0]["deadlines"],{"request_ms":0})
        route["retry"]={"attempts":0,"backoff_ms":1}
        with self.assertRaises(p.Error):p.normalize(desired,policy)

    def test_backend_tls_scope_and_validation(self):
        cert,key=self.data/"ca.pem",self.data/"key.pem"
        subprocess.run(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-days","1","-keyout",str(key),"-out",str(cert),"-subj","/CN=Test CA","-addext","basicConstraints=critical,CA:TRUE"],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        desired=copy.deepcopy(self.payload)
        route=desired["sites"][0]["routes"][0]
        route["target"]="https://10.96.0.5:8443"
        tls={"hostname":"backend.apps.example.test","ca_certificate":cert.read_text()}
        route["backend_tls"]=tls
        policy={**self.policy,"allow_backend_tls":True}
        with self.assertRaises(p.Error) as denied:p.normalize(desired,self.policy)
        self.assertEqual(denied.exception.status,403)
        normalized=p.normalize(desired,policy)
        self.assertEqual(normalized[0]["routes"][0]["backend_tls"],tls)
        p.materialize(self.data,"cluster-a",normalized,set())
        for file in (self.data/"sites/web.apps.example.test.routes").glob("*.route"):
            self.assertEqual(p.features.from_record(p.kv(file),True)["backend_tls"],tls)
        for bad in ("http://10.96.0.5:8443","https://192.0.2.5:8443","https://10.96.0.5:8443/path"):
            route["target"]=bad
            with self.subTest(target=bad),self.assertRaises(p.Error):p.normalize(desired,policy)
        route["target"]="https://10.96.0.5:8443"
        del route["backend_tls"]
        with self.assertRaises(p.Error):p.normalize(desired,policy)
        for bad in ("10.96.0.5","*.example.test","backend;example.test"):
            route["backend_tls"]={**tls,"hostname":bad}
            with self.subTest(host=bad),self.assertRaises(p.Error):p.normalize(desired,policy)
        for bad in (cert.read_text()+key.read_text(),"invalid",cert.read_text()*2):
            route["backend_tls"]={**tls,"ca_certificate":bad}
            with self.assertRaises(p.Error):p.normalize(desired,policy)
        route["backend_tls"]=tls
        route["health"]={"enabled":True}
        self.assertTrue(p.normalize(desired,policy)[0]["routes"][0]["health"]["enabled"])

    def test_independent_backend_tls_peers(self):
        cert,key=self.data/"ca.pem",self.data/"key.pem"
        subprocess.run(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-days","1","-keyout",str(key),"-out",str(cert),"-subj","/CN=Test CA","-addext","basicConstraints=critical,CA:TRUE"],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        desired=copy.deepcopy(self.payload)
        route=desired["sites"][0]["routes"][0]
        del route["target"]
        route["backends"]=[{"target":"https://10.96.0.5:8443","weight":7},{"target":"https://10.96.0.6:8443","weight":2},{"target":"http://10.96.0.7:8080","weight":1}]
        peers={b["target"]:{"hostname":f"peer{i}.example.test","ca_certificate":cert.read_text()} for i,b in enumerate(route["backends"]) if b["target"].startswith("https:")}
        route["backend_tls_peers"]=peers
        with self.assertRaises(p.Error) as exc:p.normalize(desired,self.policy)
        self.assertEqual(exc.exception.status,403)
        policy={**self.policy,"allow_backend_tls":True}
        n=p.normalize(desired,policy)
        self.assertEqual(n[0]["routes"][0]["backend_tls_peers"],peers)
        p.materialize(self.data,"cluster-a",n,set())
        for file in (self.data/"sites/web.apps.example.test.routes").glob("*.route"):
            record=p.kv(file);f=p.features.from_record(record,True)
            self.assertEqual(f["backend_tls_peers"],peers)
            config=json.loads(__import__("base64").b64decode(p.features.deadline_config(record,f)))
            self.assertEqual(config["backend_tls_peers"],peers)
        for bad in ({},dict(list(peers.items())[:1]),{**peers,"https://10.96.0.8:8443":next(iter(peers.values()))}):
            route["backend_tls_peers"]=bad
            with self.subTest(bad=list(bad)),self.assertRaises(p.Error):p.normalize(desired,policy)
        route["backend_tls_peers"]=peers
        route["backend_tls"]=next(iter(peers.values()))
        with self.assertRaises(p.Error):p.normalize(desired,policy)
        del route["backend_tls"]
        route["backends"][2]["target"]="http://192.0.2.1:8080"
        with self.assertRaises(p.Error) as exc:p.normalize(desired,policy)
        self.assertEqual(exc.exception.status,403)

    def test_private_tls_san_matching(self):
        cert,key=self.data/"cert.pem",self.data/"key.pem"
        subprocess.run(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-days","1","-keyout",str(key),"-out",str(cert),"-subj","/CN=wrong.example.test","-addext","subjectAltName=DNS:*.org,DNS:exact.example.test"],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        tls={"certificate":cert.read_text(),"private_key":key.read_text()}
        for name in ("example.org","second-example.org","*.org","exact.example.test","*"):
            self.assertEqual(p.certificate(name,tls),tls)
        for name in ("org","a.b.org","wrong.example.test","*.example.test","unrelated.net"):
            with self.subTest(name=name),self.assertRaises(p.Error):
                p.certificate(name,tls)

    def test_client_validated_frontend_opt_in(self):
        cert,key=self.data/"cert.pem",self.data/"key.pem"
        subprocess.run(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-days","1","-keyout",str(key),"-out",str(cert),"-subj","/CN=other.apps.example.test","-addext","subjectAltName=DNS:other.apps.example.test"],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        desired=copy.deepcopy(self.payload)
        desired["sites"][0]["tls"]={"certificate":cert.read_text(),"private_key":key.read_text()}
        with self.assertRaises(p.Error):p.normalize(desired,self.policy)
        policy={**self.policy,"allow_client_validated_frontend":True}
        self.assertEqual(p.normalize(desired,policy)[0]["tls"],desired["sites"][0]["tls"])
        with self.assertRaises(p.Error):p.normalize(desired,{**policy,"allow_client_validated_frontend":"true"})
        desired["sites"][0]["host"]="unscoped.example.net"
        with self.assertRaises(p.Error):p.normalize(desired,policy)
        desired["sites"][0]["host"]="web.apps.example.test"
        desired["sites"][0]["tls"]["private_key"]="not a private key"
        with self.assertRaises(p.Error):p.normalize(desired,policy)
        self.assertTrue(pa.validate(policy)["allow_client_validated_frontend"])

    def test_admin_credential_lifecycle(self):
        policy={"host_suffixes":["apps.example.test"],"backend_cidrs":["10.96.0.0/12"],"min_waf_pl":2}
        token="a"*64
        rotated="b"*64
        def action(op, text=""):
            with patch.dict("os.environ",{"LITEEDGE_CONFIG_LOCK_HELD":"1"}):
                pa.mutate(self.data,op,"cluster-a",io.StringIO(text))
        action("save",token+"\n"+json.dumps(policy))
        view=pa.list_providers(self.data)
        self.assertEqual(view[0]["policy"],policy)
        self.assertTrue(view[0]["credential_configured"])
        self.assertNotIn("token_sha256",json.dumps(view))
        self.assertNotIn(token,json.dumps(view))
        self.assertEqual(pa.p.auth(self.data,"cluster-a","Bearer "+token)["min_waf_pl"],2)
        self.apply()
        with self.assertRaises(pa.p.Error):action("save","\n"+json.dumps(policy))
        with self.assertRaises(pa.p.Error):action("delete")
        action("rotate",rotated+"\n")
        with self.assertRaises(pa.p.Error):pa.p.auth(self.data,"cluster-a","Bearer "+token)
        self.assertEqual(pa.p.auth(self.data,"cluster-a","Bearer "+rotated)["min_waf_pl"],2)
        self.apply({"revision":1,"sites":[]})
        action("delete")
        action("save",token+"\n"+json.dumps(policy))
        self.assertEqual(pa.list_providers(self.data)[0]["revision"],2)
        with self.assertRaises(pa.p.Error):action("save","\n"+json.dumps({**policy,"allow_catch_all_tls":True}))
        self.assertEqual(pa.list_providers(self.data)[0]["policy"],policy)
        with self.assertRaises(pa.p.Error):action("save","\n"+json.dumps({**policy,"waf_profiles":{"bad":{"min_waf_pl":1}}}))

    def test_create_update_delete_and_noop(self):
        r = self.apply()
        self.assertEqual(r["revision"],1)
        self.assertEqual(self.calls,["render","reload"])
        host = "web.apps.example.test"
        self.assertEqual(p.kv(self.data/"sites"/(host+".site"))["PROVIDER"],"cluster-a")
        records = [p.kv(x) for x in (self.data/"sites"/(host+".routes")).glob("*.route")]
        self.assertEqual({(x["MATCH"],x["PATH"]) for x in records},{("prefix","/foo/"),("exact","/foo")})
        self.assertTrue(all(x["WAF"]=="1" and x["WAF_PL"]=="2" for x in records))
        self.payload["revision"]=1
        self.assertFalse(self.apply()["changed"])
        self.assertEqual(self.calls,["render","reload"])
        self.payload["sites"][0]["routes"][0]["target"]="http://10.96.0.6:8080"
        self.assertEqual(self.apply()["revision"],2)
        self.assertEqual(self.apply({"revision":2,"sites":[]})["hosts"],[])
        self.assertFalse((self.data/"sites"/(host+".site")).exists())
        self.assertTrue((self.data/"sites/manual.site").exists())
        self.assertEqual((self.data/"certs/manual.example.test/privkey.pem").read_text(),"manual-key")
    def test_native_drift_is_repaired_and_quarantine_is_visible(self):
        self.apply()
        host="web.apps.example.test"
        route=next((self.data/"sites"/(host+".routes")).glob("*.route"))
        route.write_text(route.read_text().replace("WAF_PL=2","WAF_PL=1"))
        self.payload["revision"]=1
        result=self.apply()
        self.assertTrue(result["changed"])
        self.assertEqual(result["revision"],2)
        self.assertTrue(all(p.kv(x)["WAF_PL"]=="2" for x in (self.data/"sites"/(host+".routes")).glob("*.route")))
        self.payload["revision"]=2
        spec=self.payload["sites"][0]["routes"][0]
        spec.pop("target")
        spec.update(backends=[{"target":"invalid","weight":1}],quarantined=True)
        self.apply()
        self.assertTrue(all(p.kv(x)["PROVIDER_QUARANTINED"]=="1" for x in (self.data/"sites"/(host+".routes")).glob("*.route")))
        spec["backends"][0]["target"]="http://10.96.0.5:8080"
        self.payload["revision"]=3
        with self.assertRaises(p.Error):self.apply()

    def test_validation_is_nonmutating_and_attributed(self):
        current,sites,old=p.validate(self.data,"cluster-a",self.payload,self.policy)
        self.assertEqual(current["revision"],0)
        self.assertEqual(len(sites),1)
        self.assertFalse(old)
        self.assertFalse(p.state_path(self.data,"cluster-a").exists())
        self.assertFalse(self.calls)
        payload=copy.deepcopy(self.payload)
        payload["sites"][0]["routes"][0]["waf_profile"]="unapproved"
        with self.assertRaises(p.Error) as cm:p.validate(self.data,"cluster-a",payload,self.policy)
        self.assertEqual(cm.exception.location,{"site_index":0,"route_index":0,"field":"waf_profile"})
        payload=copy.deepcopy(self.payload)
        payload["sites"][0]["host"]="outside.example.test"
        with self.assertRaises(p.Error) as cm:p.validate(self.data,"cluster-a",payload,self.policy)
        self.assertEqual(cm.exception.location,{"site_index":0})
        payload=copy.deepcopy(self.payload)
        payload["revision"]=10
        with self.assertRaises(p.Error) as cm:p.validate(self.data,"cluster-a",payload,self.policy)
        self.assertIsNone(cm.exception.location)
        self.assertFalse(self.calls)
        self.assertFalse(p.state_path(self.data,"cluster-a").exists())

    def test_stale_revision(self):
        self.apply()
        with self.assertRaises(p.Error) as cm:
            self.apply()
        self.assertEqual(cm.exception.status,409)
    def test_scope_injection_and_waf_floor(self):
        for field,value in [("target","http://127.0.0.1:80"),("target","http://10.96.0.5:8080;"),("path","/x;"),("path","/%2e"),("waf_pl",1),("rate_count",1000000)]:
            bad=copy.deepcopy(self.payload)
            bad["sites"][0]["routes"][0][field]=value
            with self.subTest(field=field,value=value),self.assertRaises(p.Error):
                self.apply(bad)
        self.assertEqual(self.calls,[])
    def test_manual_alias_conflict(self):
        (self.data/"sites/manual.site").write_text("HOST=manual.example.test\nALIASES=web.apps.example.test\n")
        with self.assertRaises(p.Error) as cm:
            self.apply()
        self.assertEqual(cm.exception.status,409)
    def test_cross_provider_conflict(self):
        self.apply()
        with self.assertRaises(p.Error) as cm:
            p.apply(self.data,"cluster-b",self.payload,self.policy,self.render,self.reload)
        self.assertEqual(cm.exception.status,409)
    def test_rollback(self):
        self.apply()
        before = {x.name:x.read_bytes() for x in (self.data/"sites").glob("*.site")}
        changed=copy.deepcopy(self.payload)
        changed["revision"]=1
        changed["sites"][0]["host"]="new.apps.example.test"
        def reject(data):
            (data/"nginx/generated").write_text("bad")
            raise RuntimeError("renderer failure")
        with self.assertRaises(p.Error) as cm:
            self.apply(changed,reject)
        self.assertEqual(cm.exception.status,422)
        self.assertEqual(before,{x.name:x.read_bytes() for x in (self.data/"sites").glob("*.site")})
        self.assertEqual(p.state(self.data,"cluster-a")["revision"],1)
        self.assertEqual((self.data/"nginx/generated").read_text(),"rendered")
        self.assertFalse(p.journal(self.data).exists())
    def test_degraded_rejected(self):
        with self.assertRaises(p.Error):
            self.apply(render=lambda d: {"web.apps.example.test"})
        self.assertEqual(p.state(self.data,"cluster-a")["revision"],0)
    def test_bearer_scoped(self):
        token="A"*43
        (self.data/"providers/cluster-a.json").write_text(json.dumps({**self.policy,"token_sha256":hashlib.sha256(token.encode()).hexdigest()}))
        self.assertEqual(p.auth(self.data,"cluster-a","Bearer "+token)["min_waf_pl"],2)
        for name, header in [("cluster-b","Bearer "+token),("cluster-a","Basic "+token),("cluster-a","Bearer "+"B"*43)]:
            with self.assertRaises(p.Error):
                p.auth(self.data,name,header)
    def test_approved_profile_and_floor(self):
        self.policy["waf_profiles"]={"strict":{"min_waf_pl":3,"plugins":["approved-plugin"],"disabled_rules":[123456]}}
        self.policy["default_waf_profile"]="strict"
        self.apply()
        records=[p.kv(x) for x in (self.data/"sites/web.apps.example.test.routes").glob("*.route")]
        self.assertTrue(all(x["WAF_PL"]=="3" and x["WAF_PLUGINS"]=="approved-plugin" and x["WAF_DISABLED"]=="123456" for x in records))
        for field,value in [("waf_profile","not-approved"),("waf_pl",2),("waf_disabled",[123]),("waf_plugins",["arbitrary"])]:
            bad=copy.deepcopy(self.payload);bad["revision"]=1
            bad["sites"][0]["routes"][0][field]=value
            with self.subTest(field=field),self.assertRaises(p.Error):self.apply(bad)
        self.assertEqual(p.state(self.data,"cluster-a")["revision"],1)

    def test_header_operations(self):
        route=self.payload["sites"][0]["routes"][0]
        route["request_headers"]=[{"op":"set","name":"X-Color","value":"blue"},{"op":"add","name":"X-Mix","value":"green"},{"op":"remove","name":"X-Remove"}]
        self.apply()
        records=[p.kv(x) for x in (self.data/"sites/web.apps.example.test.routes").glob("*.route")]
        self.assertTrue(all(x["GW_HEADERS_B64"] for x in records))
        bad=copy.deepcopy(self.payload);bad["revision"]=1
        bad["sites"][0]["routes"][0]["request_headers"]=[{"op":"set","name":"X-Forwarded-For","value":"example"}]
        with self.assertRaises(p.Error):self.apply(bad)

    def test_wildcard_scope_and_overlap(self):
        wildcard=copy.deepcopy(self.payload)
        wildcard["sites"][0]["host"]="*.apps.example.test"
        with self.assertRaises(p.Error):self.apply(wildcard)
        self.policy["allow_wildcards"]=True
        self.apply(wildcard)
        self.assertTrue((self.data/"sites/_.apps.example.test.site").exists())
        self.assertEqual(p.state(self.data,"cluster-a")["hosts"],["*.apps.example.test"])
        with self.assertRaises(p.Error) as cm:
            p.apply(self.data,"cluster-b",self.payload,self.policy,self.render,self.reload)
        self.assertEqual(cm.exception.status,409)
        bad=copy.deepcopy(wildcard);bad["revision"]=1;bad["sites"][0]["host"]="*.example.test"
        with self.assertRaises(p.Error):self.apply(bad)
        self.assertTrue(p.overlap("*.apps.example.test","*.nested.apps.example.test"))
        self.assertFalse(p.overlap("*.apps.example.test","apps.example.test"))

    def test_catchall_requires_exclusive_scope(self):
        payload=copy.deepcopy(self.payload);payload["sites"][0]["host"]="*"
        with self.assertRaises(p.Error):self.apply(payload)
        self.policy["allow_catch_all"]=True
        with self.assertRaises(p.Error) as cm:self.apply(payload)
        self.assertEqual(cm.exception.status,409)
        (self.data/"sites/manual.site").unlink()
        self.assertEqual(self.apply(payload)["hosts"],["*"])
        self.assertTrue((self.data/"sites/_.site").exists())

    def test_tls_reject_and_hostname_precedence_validation(self):
        payload=copy.deepcopy(self.payload)
        payload["sites"][0]["routes"][0]["host_priority"]=1254
        with self.assertRaises(p.Error):self.apply(payload)
        payload["sites"][0]["routes"][0]["host_priority"]=1253
        self.apply(payload)
        site=self.data/"sites/web.apps.example.test.site"
        self.assertEqual(p.kv(site)["GW_DISPATCH"],"1")
        route=next((self.data/"sites/web.apps.example.test.routes").glob("*.route"))
        self.assertEqual(p.kv(route)["GW_HOST_PRIORITY"],"1253")
        bad=copy.deepcopy(payload);bad["revision"]=1
        bad["sites"][0]["tls_reject"]=True
        with self.assertRaises(p.Error):self.apply(bad)
        reject={"revision":1,"sites":[{"host":"web.apps.example.test","listeners":["https"],"tls_reject":True,"routes":[]}]}
        self.apply(reject)
        self.assertEqual(p.kv(site)["GW_TLS_REJECT"],"1")
        self.assertEqual(list((self.data/"sites/web.apps.example.test.routes").glob("*.route")),[])

    def test_shared_typed_query_and_path_contract(self):
        payload=copy.deepcopy(self.payload)
        route=payload["sites"][0]["routes"][0]
        route["query_matches"]=[{"name":"Version","value":"one"}]
        route["rewrite"]={"hostname":"backend.apps.example.test","path":{"type":"prefix","value":"/v2"}}
        normalized=p.normalize(payload,self.policy)
        features=normalized[0]["routes"][0]
        self.assertEqual(features["query_matches"],[{"name":"Version","value":"one"}])
        self.assertEqual(features["rewrite"]["path"]["value"],"/v2")
        route["rewrite"]["hostname"]="outside.example.org"
        with self.assertRaises(p.Error):p.normalize(payload,self.policy)
        route["rewrite"]["hostname"]="backend.apps.example.test"
        route["rewrite"]["path"]["value"]="/bad;return"
        with self.assertRaises(p.Error):p.normalize(payload,self.policy)
        route["rewrite"]["path"]["value"]="/v2"
        route["query_matches"][0]["value"]="two&other=one"
        with self.assertRaises(p.Error):p.normalize(payload,self.policy)

    def test_response_header_validation_and_single_wildcard(self):
        payload=copy.deepcopy(self.payload)
        route=payload["sites"][0]["routes"][0]
        route["response_headers"]=[{"op":"add","name":"X-Result","value":"good"},{"op":"remove","name":"X-Remove"}]
        self.policy.update(allow_wildcards=True,allow_catch_all=True)
        payload["sites"][0].update(host="*.apps.example.test",wildcard_single=True,listeners=["http"])
        route["schemes"]=["http"]
        normalized=p.normalize(payload,self.policy)
        self.assertTrue(normalized[0]["wildcard_single"])
        self.assertEqual(normalized[0]["routes"][0]["response_headers"][1]["name"],"x-result")
        self.apply(payload)
        records=list((self.data/"sites/_.apps.example.test.routes").glob("*.route"))
        self.assertTrue(records)
        self.assertTrue(p.kv(records[0])["GW_RESPONSE_HEADERS_B64"])
        for name in ("X-Frame-Options","X-Content-Type-Options","X-Forwarded-For","X-Powered-By"):
            route["response_headers"]=[{"op":"remove","name":name}]
            with self.assertRaises(p.Error):p.normalize(payload,self.policy)
        route["response_headers"]=[]
        payload["sites"].append({"host":"*.sub.apps.example.test","routes":[{"match":"prefix","path":"/","target":"http://10.96.0.5:8080","schemes":["http"]}]})
        with self.assertRaises(p.Error):p.normalize(payload,self.policy)
        payload["sites"].pop()
        payload["sites"][0]["host"]="web.apps.example.test"
        with self.assertRaises(p.Error):p.normalize(payload,self.policy)

    def test_exact_precedes_synthetic_prefix(self):
        routes=self.payload["sites"][0]["routes"]
        routes.append({"match":"exact","path":"/foo","target":"http://10.96.0.7:8080"})
        self.apply()
        records=[p.kv(x) for x in (self.data/"sites/web.apps.example.test.routes").glob("*.route")]
        self.assertEqual(next(x["TARGET"] for x in records if x["MATCH"]=="exact"),"http://10.96.0.7:8080")

if __name__ == "__main__":
    unittest.main(verbosity=2)
