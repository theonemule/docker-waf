#!/usr/bin/env bash
# Disposable cluster: no modification of the user's Kubernetes context.
set -euo pipefail
edge_image="$1"; controller_image="$2"; tmp=$(mktemp -d); name="lightedge-btls-$(openssl rand -hex 4)"
export KUBECONFIG="$tmp/kubeconfig"
export HELM_CACHE_HOME="$tmp/helm-cache" HELM_CONFIG_HOME="$tmp/helm-config" HELM_DATA_HOME="$tmp/helm-data"
cleanup(){
 rc=$?
 if ((rc));then kubectl -n lightedge-system get pods||true; kubectl -n lightedge-system logs deploy/test-lightedge --tail=50||true; kubectl -n apps get gateways,httproutes,backendtlspolicies -o yaml||true;fi
 kind delete cluster --name "$name"||true;rm -rf "$tmp"
}
trap cleanup EXIT
kind create cluster --name "$name" --kubeconfig "$KUBECONFIG" --wait 120s
kind load docker-image --name "$name" "$edge_image" "$controller_image"
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io crd/referencegrants.gateway.networking.k8s.io crd/backendtlspolicies.gateway.networking.k8s.io --timeout=90s
kubectl create namespace apps
kubectl create namespace lightedge-system
umask 077
openssl rand -hex 32 >"$tmp/token";openssl rand -hex 24 >"$tmp/password"
dns=test-lightedge-appliance.lightedge-system.svc
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/admin.key" -out "$tmp/admin.crt" -subj "/CN=$dns" -addext "subjectAltName=DNS:$dns" >/dev/null 2>&1
hash=$(tr -d '\n' <"$tmp/token"|sha256sum|cut -d' ' -f1)
jq -n --arg hash "$hash" '{token_sha256:$hash,host_suffixes:["apps.example.test"],backend_cidrs:["10.96.0.0/12"],min_waf_pl:1,allow_backend_tls:true,extra_https_ports:[8443]}' >"$tmp/provider.json"
kubectl -n lightedge-system create secret generic lightedge-provider --from-file=token="$tmp/token" --from-file=ca.crt="$tmp/admin.crt" --from-file=provider.json="$tmp/provider.json"
kubectl -n lightedge-system create secret tls lightedge-admin-tls --cert="$tmp/admin.crt" --key="$tmp/admin.key"
kubectl -n lightedge-system create secret generic lightedge-admin --from-file=password="$tmp/password"
for ca in trusted other;do
 openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$ca CA" -addext 'basicConstraints=critical,CA:TRUE' -keyout "$tmp/$ca.key" -out "$tmp/$ca.crt" >/dev/null 2>&1
done
openssl req -new -newkey rsa:2048 -nodes -subj '/CN=backend.apps.example.test' -keyout "$tmp/backend.key" -out "$tmp/backend.csr" >/dev/null 2>&1
printf 'basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:backend.apps.example.test\nextendedKeyUsage=serverAuth\n' >"$tmp/ext"
openssl x509 -req -in "$tmp/backend.csr" -CA "$tmp/trusted.crt" -CAkey "$tmp/trusted.key" -CAcreateserial -days 2 -extfile "$tmp/ext" -out "$tmp/backend.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/front.key" -out "$tmp/front.crt" -subj '/CN=tls.apps.example.test' -addext 'subjectAltName=DNS:tls.apps.example.test' >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/extra.key" -out "$tmp/extra.crt" -subj '/CN=tls.apps.example.test' -addext 'subjectAltName=DNS:tls.apps.example.test' >/dev/null 2>&1
kubectl -n apps create secret tls extra-cert --cert="$tmp/extra.crt" --key="$tmp/extra.key"
kubectl -n apps create secret tls backend-cert --cert="$tmp/backend.crt" --key="$tmp/backend.key"
kubectl -n apps create secret tls frontend-cert --cert="$tmp/front.crt" --key="$tmp/front.key"
kubectl -n apps create configmap backend-ca --from-file=ca.crt="$tmp/trusted.crt"
kubectl -n apps create configmap frontend-ca --from-file=ca.crt="$tmp/front.crt" --from-file=extra.crt="$tmp/extra.crt"
cat >"$tmp/backend.py" <<'PY'
import ssl,threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body=("encrypted" if self.server.server_port==8443 else "plain").encode()
        self.send_response(200);self.send_header("Content-Length",str(len(body)));self.end_headers();self.wfile.write(body)
plain=ThreadingHTTPServer(("0.0.0.0",8080),H)
threading.Thread(target=plain.serve_forever,daemon=True).start()
tls=ThreadingHTTPServer(("0.0.0.0",8443),H)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/cert/tls.crt","/cert/tls.key")
def sni(sock,name,ctx):
    if name!="backend.apps.example.test":return ssl.ALERT_DESCRIPTION_UNRECOGNIZED_NAME
ctx.set_servername_callback(sni)
tls.socket=ctx.wrap_socket(tls.socket,server_side=True)
tls.serve_forever()
PY
kubectl -n apps create configmap backend-code --from-file=backend.py="$tmp/backend.py"
cat <<MANIFEST | kubectl -n apps apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: backend}
spec:
  replicas: 1
  selector: {matchLabels: {app: backend}}
  template:
    metadata: {labels: {app: backend}}
    spec:
      containers:
      - name: backend
        image: $edge_image
        command: [python3,/code/backend.py]
        ports: [{containerPort: 8080},{containerPort: 8443}]
        volumeMounts:
        - {name: cert,mountPath: /cert,readOnly: true}
        - {name: code,mountPath: /code,readOnly: true}
        - {name: front,mountPath: /front,readOnly: true}
      volumes:
      - {name: cert,secret: {secretName: backend-cert}}
      - {name: code,configMap: {name: backend-code}}
      - {name: front,configMap: {name: frontend-ca}}
---
apiVersion: v1
kind: Service
metadata: {name: backend}
spec:
  selector: {app: backend}
  ports:
  - {name: plain,port: 8080,targetPort: 8080}
  - {name: tls,port: 8443,targetPort: 8443}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: edge}
spec:
  gatewayClassName: lightedge
  listeners:
  - {name: http,protocol: HTTP,port: 80,hostname: tls.apps.example.test}
  - name: https
    protocol: HTTPS
    port: 443
    hostname: tls.apps.example.test
    tls: {certificateRefs: [{name: frontend-cert}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: secure}
spec:
  parentRefs: [{name: edge}]
  hostnames: [tls.apps.example.test]
  rules:
  - matches: [{path: {type: Exact,value: /secure}}]
    backendRefs: [{name: backend,port: 8443}]
  - matches: [{path: {type: Exact,value: /plain}}]
    backendRefs: [{name: backend,port: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata: {name: winner}
spec:
  targetRefs: [{group: "",kind: Service,name: backend,sectionName: tls}]
  validation:
    hostname: backend.apps.example.test
    caCertificateRefs: [{group: "",kind: ConfigMap,name: backend-ca}]
MANIFEST
helm upgrade --install test deploy/kubernetes/helm/lightedge -n lightedge-system --set appliance.enabled=true --set "appliance.image=$edge_image" --set appliance.serviceType=ClusterIP --set "image.repository=${controller_image%:*}" --set "image.tag=${controller_image##*:}" --set controller.enableIngress=false --set controller.enablePolicies=true --set 'appliance.extraHTTPSPorts[0].port=8443' --set 'appliance.extraHTTPSPorts[0].targetPort=18443' --set 'controller.extraHTTPSPorts[0]=8443'
kubectl -n apps rollout status deploy/backend --timeout=120s
kubectl -n lightedge-system rollout status deploy/test-lightedge --timeout=180s
ip=$(kubectl -n lightedge-system get svc test-lightedge-appliance-public -o jsonpath='{.spec.clusterIP}')
request(){ kubectl -n apps exec deploy/backend -- curl -fsS --max-time 5 -H 'Host: tls.apps.example.test' "http://$ip/$1"; }
status(){ kubectl -n apps exec deploy/backend -- curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -H 'Host: tls.apps.example.test' "http://$ip/$1"; }
policy(){ kubectl -n apps get backendtlspolicy "$1" -o json|jq -e --arg reason "$2" 'any(.status.ancestors[]?;.ancestorRef.name=="edge" and any(.conditions[];.type=="Accepted" and .reason==$reason))' >/dev/null; }
wait_until(){ local i;for i in $(seq 1 60);do if "$@";then return;fi;sleep 2;done;return 1;}
ready(){ [[ "$(request secure 2>/dev/null)" == encrypted ]] && [[ "$(request plain 2>/dev/null)" == plain ]] && policy winner Accepted; }
wait_until ready
test "$(kubectl -n apps exec deploy/backend -- curl -fsS --max-time 5 --cacert /front/ca.crt --resolve "tls.apps.example.test:443:$ip" https://tls.apps.example.test/secure)" = encrypted
echo 'PASS HTTP→TLS and HTTPS→TLS, named Service port selection and policy ancestor status'
# A later conflict must not replace the already accepted winner.
sleep 1
cat <<'MANIFEST'|kubectl -n apps apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata: {name: loser}
spec:
  targetRefs: [{group: "",kind: Service,name: backend,sectionName: tls}]
  validation:
    hostname: wrong.apps.example.test
    caCertificateRefs: [{group: "",kind: ConfigMap,name: backend-ca}]
MANIFEST
wait_until policy loser Conflicted
test "$(request secure)" = encrypted
echo 'PASS older policy wins; later conflicting policy is rejected'
# CA updates must converge without changing the Service or Route.
kubectl -n apps create configmap backend-ca --from-file=ca.crt="$tmp/other.crt" --dry-run=client -o yaml|kubectl apply -f -
badca(){ [[ "$(status secure 2>/dev/null)" == 502 ]] && [[ "$(request plain 2>/dev/null)" == plain ]]; }
wait_until badca
kubectl -n apps create configmap backend-ca --from-file=ca.crt="$tmp/trusted.crt" --dry-run=client -o yaml|kubectl apply -f -
wait_until ready
kubectl -n apps delete configmap backend-ca
missing(){ [[ "$(status secure 2>/dev/null)" == 500 ]] && [[ "$(request plain 2>/dev/null)" == plain ]] && policy winner NoValidCACertificate; }
wait_until missing
kubectl -n apps create configmap backend-ca --from-file=ca.crt="$tmp/trusted.crt"
wait_until ready
echo 'PASS CA rotation, trust mismatch, missing CA local HTTP 500 and recovery; plaintext port remains available'
# Mixed security requirements must not silently downgrade either peer.
cat <<'MANIFEST'|kubectl -n apps apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: mixed}
spec:
  parentRefs: [{name: edge}]
  hostnames: [tls.apps.example.test]
  rules:
  - matches: [{path: {type: Exact,value: /mixed}}]
    backendRefs: [{name: backend,port: 8443},{name: backend,port: 8080}]
MANIFEST
mixed(){
 local seen_plain=0 seen_tls=0 value
 for i in $(seq 1 16);do
  value="$(request mixed 2>/dev/null)" || return 1
  case "$value" in plain)seen_plain=1;;encrypted)seen_tls=1;;*)return 1;;esac
 done
 [[ "$seen_plain" == 1 && "$seen_tls" == 1 ]] && policy winner Accepted
}
wait_until mixed
kubectl -n apps delete httproute mixed
wait_until ready
echo 'PASS heterogeneous HTTP/verified HTTPS pool without plaintext downgrade'
# Provider-owned generated CA is content-addressed and repaired from desired state.
appliance=deploy/test-lightedge-appliance
kubectl -n lightedge-system exec "$appliance" -- sh -ec 'for f in /data/nginx/waf-routes/backend-ca-*.pem;do test -f "$f";printf corrupt >"$f";done'
repair(){ kubectl -n lightedge-system exec "$appliance" -- sh -ec 'for f in /data/nginx/waf-routes/backend-ca-*.pem;do test -f "$f"; grep -q "^-----BEGIN CERTIFICATE-----" "$f";done' >/dev/null 2>&1 && ready; }
wait_until repair
echo 'PASS unchanged desired snapshot repairs generated trust-bundle drift'

# Exercise a second terminating HTTPS port with its own certificate and
# backend; a route selected by port must not be visible on the original.
kubectl -n apps patch httproute secure --type=merge -p '{"spec":{"parentRefs":[{"name":"edge","sectionName":"http"},{"name":"edge","sectionName":"https"}]}}'
kubectl -n apps patch gateway edge --type=json -p '[{"op":"add","path":"/spec/listeners/-","value":{"name":"extra","protocol":"HTTPS","port":8443,"hostname":"tls.apps.example.test","tls":{"certificateRefs":[{"name":"extra-cert"}]}}}]'
cat <<'MANIFEST' | kubectl -n apps apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: extra}
spec:
  parentRefs: [{name: edge,port: 8443}]
  hostnames: [tls.apps.example.test]
  rules:
  - matches: [{path: {type: Exact,value: /secure}}]
    backendRefs: [{name: backend,port: 8080}]
MANIFEST
extra_request(){ kubectl -n apps exec deploy/backend -- curl -fsS --max-time 5 --cacert /front/extra.crt --resolve "tls.apps.example.test:8443:$ip" https://tls.apps.example.test:8443/secure; }
standard_request(){ kubectl -n apps exec deploy/backend -- curl -fsS --max-time 5 --cacert /front/ca.crt --resolve "tls.apps.example.test:443:$ip" https://tls.apps.example.test/secure; }
extra_ready(){ [[ "$(extra_request 2>/dev/null)" == plain ]] && [[ "$(standard_request 2>/dev/null)" == encrypted ]] && kubectl -n apps get gateway edge -o json |jq -e 'any(.status.listeners[]; .name=="extra" and any(.conditions[];.type=="Programmed" and .status=="True"))' >/dev/null; }
wait_until extra_ready
if kubectl -n apps exec deploy/backend -- curl -fsS --max-time 5 --cacert /front/ca.crt --resolve "tls.apps.example.test:8443:$ip" https://tls.apps.example.test:8443/secure >/dev/null 2>&1;then exit 1;fi
echo 'PASS Kubernetes additional HTTPS listener, port-selected route, independent certificates and status'
# Invalid extra listener must not affect the standard socket.
kubectl -n apps patch gateway edge --type=json -p '[{"op":"replace","path":"/spec/listeners/2/tls/certificateRefs/0/name","value":"missing-cert"}]'
extra_invalid(){ ! extra_request >/dev/null 2>&1 && [[ "$(standard_request 2>/dev/null)" == encrypted ]] && kubectl -n apps get gateway edge -o json|jq -e 'any(.status.listeners[]; .name=="extra" and any(.conditions[];.type=="ResolvedRefs" and .status=="False"))' >/dev/null; }
wait_until extra_invalid
kubectl -n apps patch gateway edge --type=json -p '[{"op":"replace","path":"/spec/listeners/2/tls/certificateRefs/0/name","value":"extra-cert"}]'
wait_until extra_ready
echo 'PASS extra HTTPS listener certificate failure isolation and recovery'
# Health policy uses the same verified backend TLS identity and CA.
cat <<'MANIFEST' | kubectl -n apps apply -f -
apiVersion: lightedge.blaize.net/v1alpha1
kind: LightEdgePolicy
metadata: {name: secure-probe}
spec:
  targetRef: {group: gateway.networking.k8s.io,kind: HTTPRoute,name: secure}
  healthCheck: {enabled: true,path: /health,interval: 5,timeout: 3,expected: "200"}
MANIFEST
kubectl -n apps wait --for=condition=Accepted lightedgepolicy/secure-probe --timeout=90s
probe_ready(){ kubectl -n lightedge-system exec "$appliance" -- bash -ec '
for route in /data/sites/tls.apps.example.test.routes/*.route;do
 if grep -q "^HEALTH_ENABLED=1$" "$route" && grep -q "^TARGET=https://" "$route";then
  target=$(sed -n "s/^TARGET=//p" "$route")
  test "$(python3 /opt/liteedge/bin/backend-tls-probe.py "$route" "$target" /health 3)" = 200
  exit
 fi
done
exit 1' >/dev/null 2>&1; }
wait_until probe_ready
echo 'PASS Kubernetes native health policy with verified upstream TLS'
