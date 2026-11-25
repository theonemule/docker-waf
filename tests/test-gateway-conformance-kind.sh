#!/usr/bin/env bash
# Run the unmodified upstream Gateway API suite in an isolated, disposable kind
# cluster. With no test name the full GATEWAY-HTTP profile is run; a single
# selected test is diagnostic only, not a conformance claim.
set -euo pipefail
edge_image="$1"
controller_image="$2"
suite_image="$3"
test_name="${4:-}"
extended_features="${5:-}"
tmp="$(mktemp -d)"
name="lightedge-conformance-$(openssl rand -hex 4)"
export KUBECONFIG="$tmp/kubeconfig"
export HELM_CACHE_HOME="$tmp/helm-cache" HELM_CONFIG_HOME="$tmp/helm-config" HELM_DATA_HOME="$tmp/helm-data"
suite_container=""
frontend_mode="${CONFORMANCE_CLIENT_VALIDATED_FRONTEND:-false}"
[[ "$frontend_mode" == true || "$frontend_mode" == false ]] || exit 2
mode=strict-frontend
if [[ "$frontend_mode" == true ]];then mode=client-validated-frontend;fi
echo "Frontend certificate mode: $mode (backend verification unchanged)"
if [[ -n "${CONFORMANCE_REPORT:-}" && ( -n "$test_name" || -n "${CONFORMANCE_TEST_REGEX:-}" ) ]];then
  echo "Filtered tests cannot produce full conformance reports" >&2;exit 2
fi
cleanup(){
  rc=$?
  if [[ "$rc" != 0 ]]; then
    kubectl -n lightedge-system get pods,pvc || true
    kubectl -n lightedge-system logs deploy/test-lightedge --tail=80 || true
    kubectl get gateways,httproutes -A || true
  fi
  if [[ -n "$suite_container" ]]; then docker rm -v "$suite_container" >/dev/null 2>&1 || true; fi
  kind delete cluster --name "$name" || true
  rm -rf "$tmp"
}
trap cleanup EXIT
kind create cluster --name "$name" --kubeconfig "$KUBECONFIG" --wait 120s
kind load docker-image --name "$name" "$edge_image" "$controller_image"
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io crd/referencegrants.gateway.networking.k8s.io --timeout=90s
umask 077
chart=deploy/kubernetes/helm/lightedge
kubectl create namespace lightedge-system
# Upstream tests run serially; temporary Gateways from different tests can
# share a slot, but simultaneous fixture Gateways must have distinct slots.
# The fixture assignments are pinned to Gateway API v1.4.0.
fixture=tests/fixtures/conformance-partitions.json
parts=(default same https all backend slot1 slot2 slot3)
credentials=()
printf '[]' >"$tmp/partitions.json"
for part in "${parts[@]}"; do
  dns="$part-lightedge-appliance.lightedge-system.svc"
  openssl rand -hex 32 >"$tmp/$part.token"
  openssl rand -hex 24 >"$tmp/$part.password"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/$part.key" -out "$tmp/$part.crt" -subj "/CN=$dns" -addext "subjectAltName=DNS:$dns" >/dev/null 2>&1
  hash=$(tr -d '\n' <"$tmp/$part.token"|sha256sum|cut -d' ' -f1)
  jq -n --argjson frontend "$frontend_mode" --arg hash "$hash" '{token_sha256:$hash,host_suffixes:["example.com","example.org","example.net","example.test","second-example.org","specific.com","wildcard.io","anotherwildcard.io","first.com","second.com","test.com","foo.com","bar.com","https-listener.org"],extra_http_ports:[8080,8090],backend_cidrs:["10.96.0.0/12","10.244.0.0/16"],min_waf_pl:1,allow_backend_tls:true,allow_client_validated_frontend:$frontend,allow_grpc:true,allow_request_deadlines:true,allow_backend_retries:true,allow_request_mirroring:true,allow_wildcards:true,allow_catch_all:true,allow_catch_all_tls:true}' >"$tmp/$part.provider"
  kubectl -n lightedge-system create secret generic "$part-provider" --from-file=provider.json="$tmp/$part.provider"
  kubectl -n lightedge-system create secret generic "$part-admin" --from-file=password="$tmp/$part.password"
  kubectl -n lightedge-system create secret tls "$part-tls" --cert="$tmp/$part.crt" --key="$tmp/$part.key"
  helm template "$part" "$chart" --show-only templates/appliance.yaml -n lightedge-system --set appliance.enabled=true --set "appliance.image=$edge_image" --set appliance.serviceType=ClusterIP --set 'appliance.extraHTTPPorts[0].port=8080,appliance.extraHTTPPorts[0].targetPort=18080,appliance.extraHTTPPorts[1].port=8090,appliance.extraHTTPPorts[1].targetPort=18090' --set "appliance.adminSecret=$part-admin" --set "appliance.adminTLSSecret=$part-tls" --set "provider.credentialsSecret=$part-provider" --set "provider.id=$part" | kubectl -n lightedge-system apply -f -
  ip=$(kubectl -n lightedge-system get svc "$part-lightedge-appliance-public" -o jsonpath='{.spec.clusterIP}')
  jq --arg part "$part" --arg ip "$ip" --arg dns "$dns" --slurpfile f "$fixture" '.+[{name:$part,addresses:[$ip],extra_http_ports:[8080,8090],targets:[{name:$part,url:("https://"+$dns+":9443"),provider_id:$part,token_file:("/credentials/"+$part+".token"),ca_file:("/credentials/"+$part+".crt")}]}]|if $part=="default" then .[-1].default=true else .[-1].gateways=$f[0][$part] end' "$tmp/partitions.json" >"$tmp/partitions.next"
  mv "$tmp/partitions.next" "$tmp/partitions.json"
  credentials+=(--from-file="$part.token=$tmp/$part.token" --from-file="$part.crt=$tmp/$part.crt")
done
for part in "${parts[@]}";do kubectl -n lightedge-system rollout status "deploy/$part-lightedge-appliance" --timeout=180s;done
kubectl -n lightedge-system create secret generic partitions --from-file=partitions.json="$tmp/partitions.json" "${credentials[@]}"
helm upgrade --install test "$chart" -n lightedge-system --set provider.partitionsSecret=partitions --set "image.repository=${controller_image%:*}" --set "image.tag=${controller_image##*:}" --set controller.enableIngress=false --set controller.gatewayCatchAllHTTPS=true --set "controller.gatewayClientValidatedFrontend=$frontend_mode" --set "controller.enableGRPC=${CONFORMANCE_GRPC:-false}"
kubectl -n lightedge-system rollout status deploy/test-lightedge --timeout=240s
kubectl wait --for=condition=Accepted gatewayclass/lightedge --timeout=90s
# Run from inside the dedicated control-plane container; Service CIDRs and
# the dedicated test cluster's admin kubeconfig are reachable there.
suite_container=$(docker create "$suite_image")
docker cp "$suite_container:/gateway-conformance.test" "$tmp/gateway-conformance.test"
# kind mounts /tmp as noexec tmpfs; use the executable container filesystem.
docker exec -i "$name-control-plane" sh -ec 'cat >/usr/local/bin/gateway-conformance.test; chmod 755 /usr/local/bin/gateway-conformance.test' < "$tmp/gateway-conformance.test"
args=(-test.v -test.timeout=25m -gateway-class=lightedge "-conformance-profiles=${CONFORMANCE_PROFILE:-GATEWAY-HTTP}")
if [[ -n "$test_name" ]]; then args+=("-run-test=$test_name"); fi
# Diagnostic subsets via Go's subtest selection; never use for a full report.
if [[ -n "${CONFORMANCE_TEST_REGEX:-}" ]];then
  [[ -z "$test_name" && -z "${CONFORMANCE_REPORT:-}" ]] || { echo 'Subtest filter is diagnostic only' >&2;exit 2;}
  args+=("-test.run=TestConformance/^${CONFORMANCE_TEST_REGEX}$")
fi
args+=("-supported-features=${CONFORMANCE_FEATURES:-Gateway,HTTPRoute}${extended_features:+,$extended_features}")
if [[ -n "${CONFORMANCE_REPORT:-}" ]]; then
  args+=("-report-output=/tmp/lightedge-conformance-report.yaml" "-organization=LightEdge" "-project=LightEdge" "-version=${CONFORMANCE_VERSION:-development}" "-mode=$mode" "-url=https://github.com/theonemule/docker-waf" "-contact=https://github.com/theonemule/docker-waf/issues")
fi
set +e
docker exec -e KUBECONFIG=/etc/kubernetes/admin.conf "$name-control-plane" /usr/local/bin/gateway-conformance.test "${args[@]}"
rc=$?
set -e
if [[ -n "${CONFORMANCE_REPORT:-}" ]]; then
  if ! docker exec "$name-control-plane" cat /tmp/lightedge-conformance-report.yaml >"$CONFORMANCE_REPORT";then
    rm -f "$CONFORMANCE_REPORT"
    echo "Upstream conformance report was not produced" >&2;rc=1
  fi
fi
exit "$rc"
