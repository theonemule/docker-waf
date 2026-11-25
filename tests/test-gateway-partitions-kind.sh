#!/usr/bin/env bash
# Two genuinely independent public Service IPs and two appliance volumes.
set -euo pipefail
edge_image="$1";controller_image="$2";tmp="$(mktemp -d)";name="lightedge-partitions-$(openssl rand -hex 4)"
export KUBECONFIG="$tmp/kubeconfig"
export HELM_CACHE_HOME="$tmp/helm-cache" HELM_CONFIG_HOME="$tmp/helm-config" HELM_DATA_HOME="$tmp/helm-data"
cleanup(){
 rc=$?
 if ((rc));then kubectl -n lightedge-system get pods || true;kubectl -n lightedge-system logs deploy/control-lightedge --tail=50 || true;kubectl -n apps get gateways,httproutes -o yaml || true;fi
 kind delete cluster --name "$name" || true;rm -rf "$tmp"
}
trap cleanup EXIT
kind create cluster --name "$name" --kubeconfig "$KUBECONFIG" --wait 120s
kind load docker-image --name "$name" "$edge_image" "$controller_image"
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io crd/referencegrants.gateway.networking.k8s.io --timeout=90s
kubectl create namespace lightedge-system
kubectl create namespace apps
umask 077
chart=deploy/kubernetes/helm/lightedge
for part in blue green;do
 dns="$part-lightedge-appliance.lightedge-system.svc"
 openssl rand -hex 32 >"$tmp/$part.token"
 openssl rand -hex 24 >"$tmp/$part.password"
 openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/$part.key" -out "$tmp/$part.crt" -subj "/CN=$dns" -addext "subjectAltName=DNS:$dns" >/dev/null 2>&1
 hash=$(tr -d '\n' <"$tmp/$part.token"|sha256sum|cut -d' ' -f1)
 jq -n --arg hash "$hash" '{token_sha256:$hash,host_suffixes:["apps.example.test"],backend_cidrs:["10.96.0.0/12"],min_waf_pl:1,allow_catch_all:true}' >"$tmp/$part.provider"
 kubectl -n lightedge-system create secret generic "$part-provider" --from-file=provider.json="$tmp/$part.provider"
 kubectl -n lightedge-system create secret generic "$part-admin" --from-file=password="$tmp/$part.password"
 kubectl -n lightedge-system create secret tls "$part-tls" --cert="$tmp/$part.crt" --key="$tmp/$part.key"
 # Render just the appliance resources, not a competing controller.
 helm template "$part" "$chart" --show-only templates/appliance.yaml -n lightedge-system --set appliance.enabled=true --set "appliance.image=$edge_image" --set appliance.serviceType=ClusterIP --set "appliance.adminSecret=$part-admin" --set "appliance.adminTLSSecret=$part-tls" --set "provider.credentialsSecret=$part-provider" --set "provider.id=$part" | kubectl -n lightedge-system apply -f -
done
blue=$(kubectl -n lightedge-system get svc blue-lightedge-appliance-public -o jsonpath='{.spec.clusterIP}')
green=$(kubectl -n lightedge-system get svc green-lightedge-appliance-public -o jsonpath='{.spec.clusterIP}')
test "$blue" != "$green"
jq -n --arg blue "$blue" --arg green "$green" '[{name:"blue",default:true,addresses:[$blue],targets:[{name:"blue",url:"https://blue-lightedge-appliance.lightedge-system.svc:9443",provider_id:"blue",token_file:"/credentials/blue.token",ca_file:"/credentials/blue.crt"}]},{name:"green",gateways:["apps/green"],addresses:[$green],targets:[{name:"green",url:"https://green-lightedge-appliance.lightedge-system.svc:9443",provider_id:"green",token_file:"/credentials/green.token",ca_file:"/credentials/green.crt"}]}]' >"$tmp/partitions.json"
kubectl -n lightedge-system create secret generic partitions --from-file=partitions.json="$tmp/partitions.json" --from-file=blue.token="$tmp/blue.token" --from-file=blue.crt="$tmp/blue.crt" --from-file=green.token="$tmp/green.token" --from-file=green.crt="$tmp/green.crt"
for part in blue green;do
cat <<MANIFEST | kubectl -n apps apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: $part}
spec:
  replicas: 1
  selector: {matchLabels: {app: $part}}
  template:
    metadata: {labels: {app: $part}}
    spec:
      containers:
        - name: backend
          image: $edge_image
          command: [/bin/sh,-ec]
          args: ["mkdir -p /tmp/www/shared; echo $part >/tmp/www/index.html; echo $part >/tmp/www/shared/index.html; exec python3 -m http.server 8080 --directory /tmp/www"]
          ports: [{containerPort: 8080}]
---
apiVersion: v1
kind: Service
metadata: {name: $part}
spec:
  selector: {app: $part}
  ports: [{port: 8080,targetPort: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: $part}
spec:
  gatewayClassName: lightedge
  listeners: [{name: http,protocol: HTTP,port: 80,hostname: shared.apps.example.test}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: $part}
spec:
  parentRefs: [{name: $part}]
  hostnames: [shared.apps.example.test]
  rules:
    - backendRefs: [{name: $part,port: 8080}]
MANIFEST
done
cat <<'MANIFEST' | kubectl -n apps apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: dual-parent}
spec:
  parentRefs: [{name: blue},{name: green}]
  hostnames: [shared.apps.example.test]
  rules:
    - matches: [{path: {type: PathPrefix,value: /shared}}]
      backendRefs: [{name: blue,port: 8080}]
MANIFEST
helm upgrade --install control "$chart" -n lightedge-system --set provider.partitionsSecret=partitions --set "image.repository=${controller_image%:*}" --set "image.tag=${controller_image##*:}" --set controller.enableIngress=false
kubectl -n lightedge-system rollout status deploy/control-lightedge --timeout=180s
kubectl -n apps rollout status deploy/blue --timeout=120s
kubectl -n apps rollout status deploy/green --timeout=120s
request(){ kubectl -n apps exec deploy/blue -- curl -fsS --max-time 5 -H 'Host: shared.apps.example.test' "http://$1/${2:-}"; }
for i in $(seq 1 45);do
 if request "$blue" 2>/dev/null|grep -qx blue && request "$green" 2>/dev/null|grep -qx green;then break;fi
 test "$i" -lt 45;sleep 2
done
test "$(request "$blue" shared/)" = blue
test "$(request "$green" shared/)" = blue
for part in blue green;do
 address="$blue";[[ "$part" == blue ]]||address="$green"
 kubectl -n apps get gateway "$part" -o json|jq -e --arg address "$address" '.status.addresses[0].value==$address and any(.status.conditions[]; .type=="Programmed" and .status=="True")' >/dev/null
done
kubectl -n apps get httproute dual-parent -o json|jq -e '(.status.parents|length)==2 and all(.status.parents[];any(.conditions[];.type=="Programmed" and .status=="True"))' >/dev/null
echo 'PASS independent public addresses, identical hostname, independent backends and multi-parent status'
kubectl -n lightedge-system scale deploy/blue-lightedge-appliance --replicas=0
kubectl -n apps patch httproute green --type merge -p '{"spec":{"rules":[{"backendRefs":[{"name":"blue","port":8080}]}]}}'
for i in $(seq 1 60);do
 if request "$green" 2>/dev/null|grep -qx blue && kubectl -n apps get httproute dual-parent -o json|jq -e 'any(.status.parents[];.parentRef.name=="blue" and any(.conditions[];.type=="Programmed" and .status=="False")) and any(.status.parents[];.parentRef.name=="green" and any(.conditions[];.type=="Programmed" and .status=="True"))' >/dev/null;then break;fi
 test "$i" -lt 60;sleep 2
done
echo 'PASS independent partition outage does not block healthy partition'
kubectl -n lightedge-system scale deploy/blue-lightedge-appliance --replicas=1
kubectl -n lightedge-system rollout status deploy/blue-lightedge-appliance --timeout=120s
for i in $(seq 1 60);do
 if request "$blue" 2>/dev/null|grep -qx blue && kubectl -n apps get httproute dual-parent -o json|jq -e '(.status.parents|length)==2 and all(.status.parents[];any(.conditions[];.type=="Programmed" and .status=="True"))' >/dev/null;then break;fi
 test "$i" -lt 60;sleep 2
done
kubectl -n apps delete gateway green
for i in $(seq 1 45);do
 if [[ "$(kubectl -n apps exec deploy/blue -- curl -sS -o /dev/null -w '%{http_code}' -H 'Host: shared.apps.example.test' "http://$green/")" == 404 ]] && kubectl -n apps get httproute dual-parent -o json|jq -e '(.status.parents|length)==1 and .status.parents[0].parentRef.name=="blue"' >/dev/null;then break;fi
 test "$i" -lt 45;sleep 2
done
test "$(request "$blue")" = blue
echo 'PASS independent recovery, Gateway deletion and per-parent status cleanup'
