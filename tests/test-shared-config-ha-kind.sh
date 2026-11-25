#!/usr/bin/env bash
# Exercise the HA chart on a disposable single-node kind cluster.
# hostPath simulates a shared filesystem; it does not certify a real RWX CSI/NFS driver.
set -euo pipefail
edge_image="$1"; controller_image="$2"
name="lightedge-shared-ha-$(openssl rand -hex 4)"
tmp="$(mktemp -d)"
export KUBECONFIG="$tmp/kubeconfig"
export HELM_CACHE_HOME="$tmp/helm-cache" HELM_CONFIG_HOME="$tmp/helm-config" HELM_DATA_HOME="$tmp/helm-data"
cleanup(){
 rc=$?
 if [[ "$rc" != 0 ]]; then
   kubectl -n lightedge-system get pods,pvc || true
   kubectl -n lightedge-system logs statefulset/test-lightedge-appliance --tail=40 || true
   kubectl -n lightedge-system logs deploy/test-lightedge --tail=40 || true
 fi
 local cleanup_rc=0
 kind delete cluster --name "$name" || cleanup_rc=$?
 # The disposable hostPath is owned by the appliance UID (10001).
 # After the cluster stops, restore access to this fixture only. Do not
 # change the real HA storage permissions or require sudo on CI163.
 if [[ "$cleanup_rc" == 0 && -d "$tmp/shared" ]]; then
   docker run --rm --network none --user 0:0 \
     --mount "type=bind,source=$tmp/shared,target=/fixture" \
     --entrypoint /bin/sh "$edge_image" -ec \
     'chown -R "$1:$2" /fixture; chmod -R u+rwX /fixture' sh "$(id -u)" "$(id -g)" || cleanup_rc=$?
 fi
 if [[ "$cleanup_rc" == 0 ]]; then
   rm -rf "$tmp" || cleanup_rc=$?
 fi
 if [[ "$cleanup_rc" != 0 ]]; then
   echo "HA test cleanup failed; retained fixture: $tmp" >&2
 fi
 # Preserve the actual test failure, or report a genuine cleanup failure.
 if [[ "$rc" != 0 ]]; then exit "$rc"; fi
 exit "$cleanup_rc"
}
trap cleanup EXIT
if [[ "${HA_MULTINODE:-0}" == 1 ]];then
  mkdir -p "$tmp/shared"
  chmod 777 "$tmp/shared"
  cat >"$tmp/kind.yaml" <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: $tmp/shared
    containerPath: /var/local/lightedge-ha
- role: worker
  extraMounts:
  - hostPath: $tmp/shared
    containerPath: /var/local/lightedge-ha
- role: worker
  extraMounts:
  - hostPath: $tmp/shared
    containerPath: /var/local/lightedge-ha
YAML
  kind create cluster --name "$name" --kubeconfig "$KUBECONFIG" --config "$tmp/kind.yaml" --wait 120s
else
  kind create cluster --name "$name" --kubeconfig "$KUBECONFIG" --wait 120s
fi
kind load docker-image --name "$name" "$edge_image" "$controller_image"
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io crd/referencegrants.gateway.networking.k8s.io --timeout=90s
kubectl create namespace lightedge-system
docker exec "$name-control-plane" sh -ec 'mkdir -p /var/local/lightedge-ha; chown 10001:10001 /var/local/lightedge-ha; chmod 700 /var/local/lightedge-ha'
printf '%s' '{"cluster_id":"lightedge-test","bootstrap_node":"test-lightedge-appliance-0","members":{"test-lightedge-appliance-0":"test-lightedge-appliance-0.test-lightedge-appliance-members.lightedge-system.svc","test-lightedge-appliance-1":"test-lightedge-appliance-1.test-lightedge-appliance-members.lightedge-system.svc"}}' |
  docker exec -i "$name-control-plane" sh -ec 'umask 077; cat >/var/local/lightedge-ha/cluster.json; chown 10001:10001 /var/local/lightedge-ha/cluster.json'
cat <<'MANIFEST' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata: {name: lightedge-shared-ha}
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath: {path: /var/local/lightedge-ha, type: Directory}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: lightedge-shared-ha, namespace: lightedge-system}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: lightedge-shared-ha
  resources: {requests: {storage: 1Gi}}
MANIFEST
umask 077
openssl rand -hex 32 >"$tmp/token"; openssl rand -hex 24 >"$tmp/password"; openssl rand -hex 32 >"$tmp/key"
dns=test-lightedge-appliance.lightedge-system.svc
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/admin.key" -out "$tmp/admin.crt" -subj "/CN=$dns" -addext "subjectAltName=DNS:$dns" >/dev/null 2>&1
hash=$(tr -d '\n' <"$tmp/token"|sha256sum|cut -d' ' -f1)
jq -n --arg hash "$hash" '{token_sha256:$hash,host_suffixes:["apps.example.test"],backend_cidrs:["10.96.0.0/12"],min_waf_pl:1}' >"$tmp/provider.json"
kubectl -n lightedge-system create secret generic lightedge-provider --from-file=token="$tmp/token" --from-file=ca.crt="$tmp/admin.crt" --from-file=provider.json="$tmp/provider.json"
kubectl -n lightedge-system create secret tls lightedge-admin-tls --cert="$tmp/admin.crt" --key="$tmp/admin.key"
kubectl -n lightedge-system create secret generic lightedge-admin --from-file=password="$tmp/password"
kubectl -n lightedge-system create secret generic lightedge-ha-key --from-file=key="$tmp/key"
helm upgrade --install test deploy/kubernetes/helm/lightedge -n lightedge-system --set appliance.enabled=true --set "appliance.image=$edge_image" --set appliance.serviceType=ClusterIP --set "image.repository=${controller_image%:*}" --set "image.tag=${controller_image##*:}" --set appliance.ha.enabled=true --set appliance.ha.existingClaim=lightedge-shared-ha --set appliance.ha.keySecret=lightedge-ha-key --set appliance.ha.bootstrap=true --set "appliance.ha.requireDistinctNodes=$( [[ "${HA_MULTINODE:-0}" == 1 ]] && echo true || echo false )"
kubectl -n lightedge-system rollout status statefulset/test-lightedge-appliance --timeout=150s
kubectl -n lightedge-system rollout status deployment/test-lightedge --timeout=120s
kubectl create namespace apps
for app in web web-canary; do
cat <<MANIFEST | kubectl -n apps apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: $app}
spec:
  replicas: 1
  selector: {matchLabels: {app: $app}}
  template:
    metadata: {labels: {app: $app}}
    spec:
      containers:
        - name: web
          image: $edge_image
          command: ["/bin/sh","-ec"]
          args: ["mkdir -p /tmp/www; echo $app >/tmp/www/index.html; exec python3 -m http.server 8080 --directory /tmp/www"]
          ports: [{containerPort: 8080}]
---
apiVersion: v1
kind: Service
metadata: {name: $app}
spec:
  selector: {app: $app}
  ports: [{port: 8080, targetPort: 8080}]
MANIFEST
done
kubectl -n apps rollout status deploy/web --timeout=90s
kubectl -n apps rollout status deploy/web-canary --timeout=90s
kubectl -n apps apply -f deploy/kubernetes/examples/ingress.yaml
traffic(){
 local node="$1" expected="$2" ip
 for i in $(seq 1 45); do
  ip=$(kubectl -n lightedge-system get pod "test-lightedge-appliance-$node" -o jsonpath='{.status.podIP}' 2>/dev/null || true)
  if [[ -n "$ip" ]] && [[ "$(kubectl -n apps exec deploy/web -- curl -fsS --max-time 2 -H 'Host: web.apps.example.test' "http://$ip:8080/" 2>/dev/null || true)" == "$expected" ]]; then return; fi
  sleep 2
 done
 return 1
}
traffic 0 web; traffic 1 web
if [[ "${HA_MULTINODE:-0}" == 1 ]];then
  n0=$(kubectl -n lightedge-system get pod test-lightedge-appliance-0 -o jsonpath='{.spec.nodeName}')
  n1=$(kubectl -n lightedge-system get pod test-lightedge-appliance-1 -o jsonpath='{.spec.nodeName}')
  test "$n0" != "$n1"
  echo "PASS independent Kubernetes nodes: $n0 and $n1 (simulated shared mount)"
fi
echo 'PASS two HA StatefulSet appliances serve one controller provider snapshot'
kubectl -n lightedge-system scale statefulset/test-lightedge-appliance --replicas=1
kubectl -n lightedge-system wait --for=delete pod/test-lightedge-appliance-1 --timeout=90s
kubectl -n apps patch ingress web --type=json -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"web-canary"}]'
traffic 0 web-canary
kubectl -n lightedge-system scale statefulset/test-lightedge-appliance --replicas=2
kubectl -n lightedge-system rollout status statefulset/test-lightedge-appliance --timeout=150s
traffic 1 web-canary
r0=$(kubectl -n lightedge-system exec test-lightedge-appliance-0 -- jq -r .revision /data/.liteedge-ha-applied.json)
r1=$(kubectl -n lightedge-system exec test-lightedge-appliance-1 -- jq -r .revision /data/.liteedge-ha-applied.json)
test "$r0" = "$r1"
echo 'PASS HA StatefulSet scale-down, single-target Kubernetes update, recovery and equal shared revision'
