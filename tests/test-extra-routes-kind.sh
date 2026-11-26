#!/usr/bin/env bash
# Isolated kind integration for all four additional route kinds.
set -euo pipefail
edge_image="$1"; controller_image="$2"; tmp="$(mktemp -d)";name="lightedge-protocols-$(openssl rand -hex 4)"
export KUBECONFIG="$tmp/kubeconfig"
export HELM_CACHE_HOME="$tmp/helm-cache" HELM_CONFIG_HOME="$tmp/helm-config" HELM_DATA_HOME="$tmp/helm-data"
grpc_image="lightedge-grpc-fixture:$(openssl rand -hex 4)"
cleanup(){
 rc=$?
 if ((rc));then kubectl -n lightedge-system get pods||true; kubectl -n lightedge-system logs deploy/test-lightedge --tail=80||true; kubectl -n apps get gateways,grpcroutes,tcproutes,udproutes,tlsroutes -o yaml||true;fi
 kind delete cluster --name "$name"||true;docker image rm "$grpc_image" >/dev/null 2>&1||true;rm -rf "$tmp"
}
trap cleanup EXIT
mkdir "$tmp/grpc"
cp tests/fixtures/grpc/main.go "$tmp/grpc/"
cat >"$tmp/grpc/Dockerfile" <<'DOCKER'
FROM golang:1.26.11-bookworm AS build
COPY main.go /main.go
RUN CGO_ENABLED=0 go build -trimpath -o /grpc /main.go
FROM alpine:3.24
COPY --from=build /grpc /grpc
USER 10001:10001
ENTRYPOINT ["/grpc"]
DOCKER
docker build --no-cache --pull -t "$grpc_image" "$tmp/grpc"
kind create cluster --name "$name" --kubeconfig "$KUBECONFIG" --wait 120s
kind load docker-image --name "$name" "$edge_image" "$controller_image" "$grpc_image"
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml
kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io crd/grpcroutes.gateway.networking.k8s.io crd/tcproutes.gateway.networking.k8s.io crd/udproutes.gateway.networking.k8s.io crd/tlsroutes.gateway.networking.k8s.io --timeout=90s
kubectl create namespace apps
kubectl create namespace backends
kubectl create namespace lightedge-system
umask 077
openssl rand -hex 32 >"$tmp/token";openssl rand -hex 24 >"$tmp/password"
dns=test-lightedge-appliance.lightedge-system.svc
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/admin.key" -out "$tmp/admin.crt" -subj "/CN=$dns" -addext "subjectAltName=DNS:$dns" >/dev/null 2>&1
hash=$(tr -d '\n' <"$tmp/token"|sha256sum|cut -d' ' -f1)
jq -n --arg hash "$hash" '{token_sha256:$hash,host_suffixes:["apps.example.test"],backend_cidrs:["10.96.0.0/12","10.244.0.0/16"],min_waf_pl:1,allow_grpc:true,allow_stream:true,allow_wildcards:true,stream_ports:{tcp:[9000],udp:[9001],tls:[9444]}}' >"$tmp/provider.json"
kubectl -n lightedge-system create secret generic lightedge-provider --from-file=token="$tmp/token" --from-file=ca.crt="$tmp/admin.crt" --from-file=provider.json="$tmp/provider.json"
kubectl -n lightedge-system create secret tls lightedge-admin-tls --cert="$tmp/admin.crt" --key="$tmp/admin.key"
kubectl -n lightedge-system create secret generic lightedge-admin --from-file=password="$tmp/password"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/backend.key" -out "$tmp/backend.crt" -subj "/CN=tls.apps.example.test" -addext "subjectAltName=DNS:tls.apps.example.test,DNS:other.apps.example.test" >/dev/null 2>&1
kubectl -n backends create secret tls backend-cert --cert="$tmp/backend.crt" --key="$tmp/backend.key"
cat >"$tmp/backend.py" <<'PY'
import socketserver,ssl,threading
class TCP(socketserver.BaseRequestHandler):
    def handle(self):
        data=self.request.recv(4096)
        self.request.sendall(str(self.server.server_address[1]).encode()+b":"+data)
class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        data,s=self.request
        s.sendto(b"udp:"+data,self.client_address)
def tcp(port,tls=False):
    srv=socketserver.ThreadingTCPServer(("0.0.0.0",port),TCP)
    if tls:
        c=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);c.load_cert_chain("/cert/tls.crt","/cert/tls.key");srv.socket=c.wrap_socket(srv.socket,server_side=True)
    srv.serve_forever()
for p,tls in [(12001,False),(12003,True),(12004,True)]:threading.Thread(target=tcp,args=(p,tls),daemon=True).start()
socketserver.ThreadingUDPServer(("0.0.0.0",12002),UDP).serve_forever()
PY
kubectl -n backends create configmap backend-code --from-file=backend.py="$tmp/backend.py"
cat <<MANIFEST | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: transport,namespace: backends}
spec:
  replicas: 1
  selector: {matchLabels: {app: transport}}
  template:
    metadata: {labels: {app: transport}}
    spec:
      containers:
      - name: transport
        image: $edge_image
        command: [python3,/code/backend.py]
        volumeMounts:
        - {name: cert,mountPath: /cert,readOnly: true}
        - {name: code,mountPath: /code,readOnly: true}
      volumes:
      - {name: cert,secret: {secretName: backend-cert}}
      - {name: code,configMap: {name: backend-code}}
---
apiVersion: v1
kind: Service
metadata: {name: transport,namespace: backends}
spec:
  selector: {app: transport}
  ports:
  - {name: tcp,port: 12001,targetPort: 12001,protocol: TCP}
  - {name: udp,port: 12002,targetPort: 12002,protocol: UDP}
  - {name: tls,port: 12003,targetPort: 12003,protocol: TCP}
  - {name: tls-two,port: 12004,targetPort: 12004,protocol: TCP}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: grpc,namespace: apps}
spec:
  replicas: 1
  selector: {matchLabels: {app: grpc}}
  template:
    metadata: {labels: {app: grpc}}
    spec:
      containers:
      - name: grpc
        image: $grpc_image
        args: ["12005"]
---
apiVersion: v1
kind: Service
metadata: {name: grpc,namespace: apps}
spec:
  selector: {app: grpc}
  ports: [{port: 12005,targetPort: 12005}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: edge,namespace: apps}
spec:
  gatewayClassName: lightedge
  listeners:
  - {name: grpc,protocol: HTTP,port: 80,hostname: grpc.apps.example.test,allowedRoutes: {kinds: [{kind: GRPCRoute}]}}
  - {name: tcp,protocol: TCP,port: 9000,allowedRoutes: {kinds: [{kind: TCPRoute}]}}
  - {name: udp,protocol: UDP,port: 9001,allowedRoutes: {kinds: [{kind: UDPRoute}]}}
  - {name: tls,protocol: TLS,port: 9444,hostname: "*.apps.example.test",tls: {mode: Passthrough},allowedRoutes: {kinds: [{kind: TLSRoute}]}}
---
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata: {name: grpc,namespace: apps}
spec:
  parentRefs: [{name: edge,sectionName: grpc}]
  hostnames: [grpc.apps.example.test]
  rules:
  - matches: [{method: {service: example.Echo,method: Call}}]
    filters: [{type: RequestHeaderModifier,requestHeaderModifier: {set: [{name: X-Route,value: gateway}]}}]
    backendRefs: [{name: grpc,port: 12005}]
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TCPRoute
metadata: {name: tcp,namespace: apps}
spec:
  parentRefs: [{name: edge,sectionName: tcp}]
  rules: [{backendRefs: [{name: transport,namespace: backends,port: 12001}]}]
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: UDPRoute
metadata: {name: udp,namespace: apps}
spec:
  parentRefs: [{name: edge,sectionName: udp}]
  rules: [{backendRefs: [{name: transport,namespace: backends,port: 12002}]}]
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata: {name: tls,namespace: apps}
spec:
  parentRefs: [{name: edge,sectionName: tls}]
  hostnames: [tls.apps.example.test]
  rules: [{backendRefs: [{name: transport,namespace: backends,port: 12003}]}]
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata: {name: tls-two,namespace: apps}
spec:
  parentRefs: [{name: edge,sectionName: tls}]
  hostnames: [other.apps.example.test]
  rules: [{backendRefs: [{name: transport,namespace: backends,port: 12004}]}]
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata: {name: tcp-tls,namespace: backends}
spec:
  from:
  - {group: gateway.networking.k8s.io,kind: TCPRoute,namespace: apps}
  - {group: gateway.networking.k8s.io,kind: TLSRoute,namespace: apps}
  to: [{group: "",kind: Service,name: transport}]
MANIFEST
helm upgrade --install test deploy/kubernetes/helm/lightedge -n lightedge-system --set appliance.enabled=true --set "appliance.image=$edge_image" --set appliance.serviceType=ClusterIP --set "image.repository=${controller_image%:*}" --set "image.tag=${controller_image##*:}" --set controller.enableIngress=false --set controller.enableGRPC=true --set 'appliance.extraTCPPorts[0].port=9000,appliance.extraTCPPorts[0].targetPort=19000,appliance.extraUDPPorts[0].port=9001,appliance.extraUDPPorts[0].targetPort=19001,appliance.extraTLSPorts[0].port=9444,appliance.extraTLSPorts[0].targetPort=19444,controller.extraTCPPorts[0]=9000,controller.extraUDPPorts[0]=9001,controller.extraTLSPorts[0]=9444'
kubectl -n backends rollout status deploy/transport --timeout=120s
kubectl -n apps rollout status deploy/grpc --timeout=120s
kubectl -n lightedge-system rollout status deploy/test-lightedge --timeout=180s
wait_until(){ for i in $(seq 1 120);do if "$@";then return 0;fi;sleep 1;done;return 1; }
condition(){ local kind="$1" name="$2" typ="$3" expected="$4" reason="$5";kubectl -n apps get "$kind" "$name" -o json|jq -e --arg typ "$typ" --arg expected "$expected" --arg reason "$reason" 'any(.status.parents[]?.conditions[]?;.type==$typ and .status==$expected and .reason==$reason)' >/dev/null; }
wait_until condition udproute udp ResolvedRefs False RefNotPermitted
echo 'PASS UDPRoute cross-namespace reference denied before grant'
cat <<MANIFEST | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata: {name: udp,namespace: backends}
spec:
  from: [{group: gateway.networking.k8s.io,kind: UDPRoute,namespace: apps}]
  to: [{group: "",kind: Service,name: transport}]
MANIFEST
for item in grpcroutes:grpc tcproutes:tcp udproutes:udp tlsroutes:tls tlsroutes:tls-two;do
 kind=${item%:*};route=${item#*:}
 wait_until condition "$kind" "$route" Accepted True Accepted
 wait_until condition "$kind" "$route" ResolvedRefs True ResolvedRefs
 wait_until condition "$kind" "$route" Programmed True Programmed
done
kubectl -n apps get gateway edge -o json|jq -e 'any(.status.listeners[];.name=="grpc" and .attachedRoutes==1 and any(.supportedKinds[];.kind=="GRPCRoute")) and any(.status.listeners[];.name=="tcp" and .attachedRoutes==1) and any(.status.listeners[];.name=="udp" and .attachedRoutes==1) and any(.status.listeners[];.name=="tls" and .attachedRoutes==2)'
public=test-lightedge-appliance-public.lightedge-system.svc
kexec(){ kubectl -n backends exec deploy/transport -- "$@"; }
kexec sh -c 'printf "\000\000\000\000\000" | curl --http2-prior-knowledge -sS -D - -o /dev/null -H "Host: grpc.apps.example.test" -H "Content-Type: application/grpc" -H "TE: trailers" --data-binary @- "http://$1/example.Echo/Call"' sh "$public" >"$tmp/headers"
grep -qi '^grpc-status: 0' "$tmp/headers";grep -qi '^x-echo-route: gateway' "$tmp/headers"
kubectl -n backends exec -i deploy/transport -- python3 - "$public" <<'PY'
import socket,ssl,sys
host=sys.argv[1]
with socket.create_connection((host,9000),3) as s:
 s.sendall(b"hello");assert s.recv(4096)==b"12001:hello"
with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
 s.settimeout(3);s.sendto(b"hello",(host,9001));assert s.recv(4096)==b"udp:hello"
for h,p in [("tls.apps.example.test",12003),("other.apps.example.test",12004)]:
 c=ssl.create_default_context(cafile="/cert/tls.crt")
 with c.wrap_socket(socket.create_connection((host,9444),3),server_hostname=h) as s:
  s.sendall(b"hello");assert s.recv(4096)==str(p).encode()+b":hello"
PY
echo 'PASS Kubernetes all four route kinds, gRPC metadata/trailers, cross-namespace grant and SNI passthrough'
# Wrong Service protocol must never send UDP traffic to a TCP backend.
kubectl -n apps patch udproute udp --type=json -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/port","value":12001}]'
wait_until condition udproute udp ResolvedRefs False BackendNotFound
# Withdrawing reference grant revokes TCP/TLS backend use, not gRPC.
kubectl -n backends delete referencegrant tcp-tls
wait_until condition tcproute tcp ResolvedRefs False RefNotPermitted
wait_until condition tlsroute tls ResolvedRefs False RefNotPermitted
wait_until condition grpcroutes grpc Programmed True Programmed
echo 'PASS protocol mismatch rejection, ReferenceGrant revocation and unrelated gRPC preservation'

# Invalid gRPC backend references are returned as UNAVAILABLE (14).
kubectl -n apps patch grpcroute grpc --type=json -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/name","value":"missing"}]'
wait_until condition grpcroute grpc ResolvedRefs False BackendNotFound
kexec sh -c 'printf "\000\000\000\000\000" | curl --http2-prior-knowledge -sS -D - -o /dev/null -H "Host: grpc.apps.example.test" -H "Content-Type: application/grpc" -H "TE: trailers" --data-binary @- "http://$1/example.Echo/Call"' sh "$public" >"$tmp/headers"
grep -qi '^grpc-status: 14' "$tmp/headers"
echo 'PASS invalid gRPC backend returns UNAVAILABLE'
