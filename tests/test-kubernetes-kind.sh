#!/usr/bin/env bash
# Creates and deletes its own disposable kind cluster, never the current context.
set -euo pipefail
edge_image="$1"
controller_image="$2"
tmp=$(mktemp -d)
name="lightedge-ci-$(openssl rand -hex 4)"
export KUBECONFIG="$tmp/kubeconfig"
export HELM_CACHE_HOME="$tmp/helm-cache" HELM_CONFIG_HOME="$tmp/helm-config" HELM_DATA_HOME="$tmp/helm-data"
cleanup() {
  rc=$?
  if [ "$rc" != 0 ]; then
    kubectl -n lightedge-system get pods || true
    kubectl -n lightedge-system logs deploy/test-lightedge --tail=50 || true
    kubectl -n lightedge-system logs deploy/test-lightedge-appliance -c appliance --tail=50 || true
    kubectl -n lightedge-system logs deploy/test-lightedge-appliance -c appliance --previous --tail=50 || true
  fi
  kind delete cluster --name "$name" || true
  rm -rf "$tmp"
}
trap cleanup EXIT
kind create cluster --name "$name" --kubeconfig "$KUBECONFIG" --wait 120s
kind load docker-image --name "$name" "$edge_image" "$controller_image"
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io crd/referencegrants.gateway.networking.k8s.io --timeout=90s
umask 077
openssl rand -hex 32 > "$tmp/token"; openssl rand -hex 24 > "$tmp/password"
dns=test-lightedge-appliance.lightedge-system.svc
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/admin.key" -out "$tmp/admin.crt" -subj "/CN=$dns" -addext "subjectAltName=DNS:$dns" >/dev/null 2>&1
hash=$(tr -d '\n' < "$tmp/token" | sha256sum | cut -d' ' -f1)
jq -n --arg hash "$hash" '{token_sha256:$hash,host_suffixes:["apps.example.test"],backend_cidrs:["10.96.0.0/12"],min_waf_pl:1,allow_wildcards:true,allow_catch_all:true,waf_profiles:{strict:{min_waf_pl:2}}}' > "$tmp/provider.json"
kubectl create namespace lightedge-system
kubectl -n lightedge-system create secret generic lightedge-provider --from-file=token="$tmp/token" --from-file=ca.crt="$tmp/admin.crt" --from-file=provider.json="$tmp/provider.json"
kubectl -n lightedge-system create secret tls lightedge-admin-tls --cert="$tmp/admin.crt" --key="$tmp/admin.key"
kubectl -n lightedge-system create secret generic lightedge-admin --from-file=password="$tmp/password"
helm upgrade --install test deploy/kubernetes/helm/lightedge -n lightedge-system --set appliance.enabled=true --set "appliance.image=$edge_image" --set appliance.serviceType=ClusterIP --set "image.repository=${controller_image%:*}" --set "image.tag=${controller_image##*:}" --set controller.enablePolicies=true --set controller.ingressWildcard=true --set controller.ingressCatchAll=true
kubectl create namespace apps
for app in web web-canary; do
cat <<MANIFEST | kubectl -n apps apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $app
spec:
  replicas: 1
  selector:
    matchLabels: {app: $app}
  template:
    metadata:
      labels: {app: $app}
    spec:
      containers:
      - name: web
        image: $edge_image
        command: ["/bin/sh","-ec"]
        args: ["mkdir -p /tmp/www; echo $app >/tmp/www/index.html; exec python3 -m http.server 8080 --directory /tmp/www"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: $app
spec:
  selector: {app: $app}
  ports:
  - port: 8080
    targetPort: 8080
MANIFEST
done
kubectl -n apps rollout status deploy/web --timeout=120s
kubectl -n apps rollout status deploy/web-canary --timeout=120s
kubectl -n apps apply -f deploy/kubernetes/examples
kubectl -n lightedge-system rollout status deploy/test-lightedge --timeout=120s
kubectl -n apps wait --for=condition=Programmed gateway/lightedge --timeout=90s
url=http://test-lightedge-appliance-public.lightedge-system.svc/
for host in web.apps.example.test gateway.apps.example.test; do
  for i in $(seq 1 30); do
    if kubectl -n apps exec deploy/web -- curl -fsS --max-time 3 -H "Host: $host" "$url"; then break; fi
    test "$i" -lt 30; sleep 2
  done
done
kubectl -n apps get httproute web -o json | jq -e 'any(.status.parents[].conditions[]; .type=="Programmed" and .status=="True")' >/dev/null
kubectl -n apps patch lightedgepolicy web --type=merge -p '{"spec":{"waf":{"profile":"strict"}}}'
kubectl -n apps wait --for=condition=Accepted lightedgepolicy/web --timeout=90s
# Header and method matching selects canary deterministically; host redirect
# is separate from proxy routing and preserves the request path and query.
cat <<'MANIFEST' | kubectl -n apps apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: conditional
spec:
  hostnames: ["gateway.apps.example.test"]
  parentRefs:
    - name: lightedge
      sectionName: http
  rules:
    - matches:
        - path: {type: Exact, value: /}
          headers:
            - {name: X-Mode, value: Canary}
          method: GET
      backendRefs:
        - {name: web-canary, port: 8080}
    - matches:
        - path: {type: Exact, value: /redirect}
      filters:
        - type: RequestRedirect
          requestRedirect:
            hostname: new.apps.example.test
            scheme: https
            statusCode: 301
MANIFEST
for i in $(seq 1 30); do
  if kubectl -n apps get httproute conditional -o json | jq -e 'any(.status.parents[]?.conditions[]?; .type=="Programmed" and .status=="True")' >/dev/null; then break; fi
  test "$i" -lt 30; sleep 2
done
for i in $(seq 1 30); do
  if test "$(kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: gateway.apps.example.test' -H 'X-Mode: Canary' "$url" 2>/dev/null)" = web-canary; then break; fi
  test "$i" -lt 30; sleep 2
done
for i in $(seq 1 3); do
  test "$(kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: gateway.apps.example.test' -H 'X-Mode: Canary' "$url")" = web-canary
done
kubectl -n apps exec deploy/web -- curl -sS -D - -o /dev/null -H 'Host: gateway.apps.example.test' "${url}redirect?test=one" | tr -d '\r' | grep -qi '^location: https://new.apps.example.test/redirect?test=one$'
echo 'PASS: Kubernetes header/method match, redirect and approved profile status'
# Verify advanced features through the Gateway resource, the actual route
# renderer and the appliance management API used by the SPA.
cat <<'MANIFEST' | kubectl -n apps apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: advanced
spec:
  parentRefs:
    - name: lightedge
      sectionName: http
  hostnames: ["gateway.apps.example.test"]
  rules:
    - matches:
        - path: {type: PathPrefix, value: /query}
          queryParams: [{name: version, value: two}]
      filters:
        - type: URLRewrite
          urlRewrite:
            path: {type: ReplaceFullPath, replaceFullPath: /}
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set: [{name: X-Route, value: query}]
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            set: [{name: X-Route-Response, value: advanced}]
      backendRefs: [{name: web-canary, port: 8080}]
    - matches:
        - path: {type: PathPrefix, value: /old}
      filters:
        - type: RequestRedirect
          requestRedirect:
            hostname: new.apps.example.test
            scheme: https
            statusCode: 302
            path: {type: ReplacePrefixMatch, replacePrefixMatch: /new}
MANIFEST
for i in $(seq 1 45); do
  if kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: gateway.apps.example.test' "${url}query/item?version=two" 2>/dev/null | grep -qx web-canary; then break; fi
  test "$i" -lt 45; sleep 2
done
test "$(kubectl -n apps exec deploy/web -- curl -sS -o /dev/null -w '%{http_code}' -H 'Host: gateway.apps.example.test' "${url}query/item?version=one")" = 404
kubectl -n apps exec deploy/web -- curl -sS -D - -o /dev/null -H 'Host: gateway.apps.example.test' "${url}old/item?x=1" | tr -d '\r' | grep -qi '^location: https://new.apps.example.test/new/item?x=1$'
# Inspect the same route read model presented to the authenticated SPA.
# The embedded appliance admin credential is only read within this fixture.
kubectl -n lightedge-system exec deploy/test-lightedge-appliance -- sh -ec 'curl -ksSf -u "admin:$ADMIN_PASSWORD" "https://127.0.0.1:9443/api/v1/site?host=gateway.apps.example.test"' |
 jq -e '.site.provider=="cluster-a" and any(.site.routes[]; .features.query_matches[0].value=="two" and .features.rewrite.path.type=="full" and .features.request_headers[0].name=="x-route") and any(.site.routes[]; .features.redirect.path.type=="prefix" and .features.redirect.path.value=="/new")' >/dev/null
kubectl -n apps exec deploy/web -- curl -sS -D - -o /dev/null -H 'Host: gateway.apps.example.test' "${url}query/item?version=two" | tr -d '\r' | grep -qi '^x-route-response: advanced$'
echo 'PASS: Gateway query and path modifiers, management API feature parity'

kubectl -n lightedge-system scale deployment/test-lightedge --replicas=0
kubectl -n lightedge-system rollout status deployment/test-lightedge --timeout=60s
kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: gateway.apps.example.test' -H 'X-Mode: Canary' "$url" | grep -q web-canary
kubectl -n lightedge-system scale deployment/test-lightedge --replicas=1
kubectl -n lightedge-system rollout status deployment/test-lightedge --timeout=120s
echo 'PASS: controller outage and restart preserve traffic'
helm upgrade test deploy/kubernetes/helm/lightedge -n lightedge-system --reuse-values --set controller.interval=3s
kubectl -n lightedge-system rollout status deployment/test-lightedge --timeout=120s
kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: gateway.apps.example.test' -H 'X-Mode: Canary' "$url" | grep -q web-canary
echo 'PASS: Helm rolling controller upgrade preserves traffic'

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$tmp/tls.key" -out "$tmp/tls.crt" -subj /CN=web.apps.example.test -addext subjectAltName=DNS:web.apps.example.test >/dev/null 2>&1
kubectl -n apps create secret tls web-tls --cert="$tmp/tls.crt" --key="$tmp/tls.key"
kubectl -n apps patch ingress web --type=merge -p '{"spec":{"tls":[{"hosts":["web.apps.example.test"],"secretName":"web-tls"}]}}'
kubectl -n apps exec -i deploy/web -- sh -c 'cat >/tmp/edge-test-ca.crt' < "$tmp/tls.crt"
ip=$(kubectl -n lightedge-system get svc test-lightedge-appliance-public -o jsonpath='{.spec.clusterIP}')
for i in $(seq 1 30); do
  kubectl -n apps exec -i deploy/web -- sh -c 'cat >/tmp/edge-test-ca.crt' < "$tmp/tls.crt"
  if kubectl -n apps exec deploy/web -- curl -fsS --max-time 3 --cacert /tmp/edge-test-ca.crt --resolve "web.apps.example.test:443:$ip" https://web.apps.example.test/; then break; fi
  test "$i" -lt 30; sleep 2
done
code=$(kubectl -n apps exec deploy/web -- curl -sS --cacert /tmp/edge-test-ca.crt --resolve "web.apps.example.test:443:$ip" --get --data-urlencode 'q=<script>alert(1)</script>' -o /dev/null -w '%{http_code}' https://web.apps.example.test/)
test "$code" = 403
kubectl -n apps delete ingress web
for i in $(seq 1 30); do
  code=$(kubectl -n apps exec deploy/web -- curl -sS -o /dev/null -w '%{http_code}' -H 'Host: web.apps.example.test' "$url")
  if [ "$code" = 404 ]; then break; fi
  test "$i" -lt 30; sleep 2
done
kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: gateway.apps.example.test' "$url"
# Add a wildcard listener and a more-specific, route-less listener.
kubectl -n apps patch gateway lightedge --type=json -p '[{"op":"add","path":"/spec/listeners/-","value":{"name":"wild","protocol":"HTTP","port":80,"hostname":"*.wild.apps.example.test"}},{"op":"add","path":"/spec/listeners/-","value":{"name":"reserved","protocol":"HTTP","port":80,"hostname":"reserved.wild.apps.example.test"}}]'
cat <<'MANIFEST' | kubectl -n apps apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wildcard
spec:
  parentRefs:
    - name: lightedge
      sectionName: wild
  rules:
    - backendRefs:
        - {name: web-canary, port: 8080}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: invalid-backend
spec:
  hostnames: ["gateway.apps.example.test"]
  parentRefs:
    - name: lightedge
      sectionName: http
  rules:
    - matches:
        - path: {type: Exact, value: /invalid}
      backendRefs:
        - {name: does-not-exist, port: 8080}
    - matches:
        - path: {type: Exact, value: /mixed}
      backendRefs:
        - {name: web, port: 8080, weight: 3}
        - {name: does-not-exist, port: 8080, weight: 1}
MANIFEST
for i in $(seq 1 45); do
  if kubectl -n apps get httproute wildcard -o json | jq -e 'any(.status.parents[]?.conditions[]?; .type=="Programmed" and .status=="True")' >/dev/null &&
     kubectl -n apps get httproute invalid-backend -o json | jq -e 'any(.status.parents[]?.conditions[]?; .type=="ResolvedRefs" and .status=="False" and .reason=="BackendNotFound")' >/dev/null; then break; fi
  test "$i" -lt 45; sleep 2
done
for i in $(seq 1 30); do
  if test "$(kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: nested.sub.wild.apps.example.test' "$url" 2>/dev/null)" = web-canary; then break; fi
  test "$i" -lt 30; sleep 2
done
test "$(kubectl -n apps exec deploy/web -- curl -sS -o /dev/null -w '%{http_code}' -H 'Host: reserved.wild.apps.example.test' "$url")" = 404
test "$(kubectl -n apps exec deploy/web -- curl -sS -o /dev/null -w '%{http_code}' -H 'Host: gateway.apps.example.test' "${url}invalid")" = 500
# The stock Python backend serves files, so /mixed returns 404 when the
# healthy backend receives the request, not 200; distinguish it from 500.
counts=$(kubectl -n apps exec deploy/web -- sh -c 'for i in $(seq 1 40); do curl -sS -o /dev/null -w "%{http_code}\n" -H "Host: gateway.apps.example.test" http://test-lightedge-appliance-public.lightedge-system.svc/mixed; done' | sort | uniq -c)
printf '%s\n' "$counts"
printf '%s\n' "$counts" | awk '$2==500 && $1>=7 && $1<=15 {ok=1} END{exit !ok}'
echo 'PASS: Kubernetes wildcard, reserved listener and invalid backend traffic/status'
# Same listener: a specific route must inherit a broader route's unmatched paths.
# Invalid resources on the same Gateway and an unrelated broken Ingress must
# not block a new healthy route from being applied.
kubectl -n apps patch gateway lightedge --type=json -p '[{"op":"add","path":"/spec/listeners/-","value":{"name":"broken-tls","protocol":"HTTPS","port":443,"hostname":"broken.apps.example.test","tls":{"certificateRefs":[{"name":"missing-secret"}]}}}]'
cat <<'MANIFEST' | kubectl -n apps apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: exact-wildcard
spec:
  parentRefs:
    - name: lightedge
      sectionName: wild
  hostnames: ["specific.wild.apps.example.test"]
  rules:
    - matches:
        - path: {type: Exact, value: /}
          headers: [{name: X-Mode, value: Primary}]
      backendRefs: [{name: web, port: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: unsupported-route
spec:
  hostnames: ["gateway.apps.example.test"]
  parentRefs:
    - name: lightedge
      sectionName: http
  rules:
    - matches:
        - path: {type: Exact, value: /partial-should-not-exist}
      backendRefs: [{name: web-canary, port: 8080}]
    - filters:
        - type: ExtensionRef
          extensionRef: {group: example.test, kind: UnknownFilter, name: unsupported}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: missing-service
spec:
  ingressClassName: lightedge
  rules:
    - host: missing.apps.example.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: missing
                port: {number: 8080}
MANIFEST
for i in $(seq 1 45); do
  if kubectl -n apps get httproute unsupported-route -o json | jq -e 'any(.status.parents[]?.conditions[]?; .type=="Accepted" and .status=="False" and .reason=="UnsupportedValue")' >/dev/null &&
     kubectl -n apps get gateway lightedge -o json | jq -e 'any(.status.listeners[]?; .name=="broken-tls" and any(.conditions[]?; .type=="ResolvedRefs" and .status=="False" and .reason=="InvalidCertificateRef"))' >/dev/null &&
     kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: specific.wild.apps.example.test' -H 'X-Mode: Primary' "$url" 2>/dev/null | grep -qx web; then break; fi
  test "$i" -lt 45; sleep 2
done
test "$(kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: specific.wild.apps.example.test' "$url")" = web-canary
test "$(kubectl -n apps exec deploy/web -- curl -sS -o /dev/null -w '%{http_code}' -H 'Host: missing.apps.example.test' "$url")" = 500
test "$(kubectl -n apps exec deploy/web -- curl -sS -o /dev/null -w '%{http_code}' -H 'Host: gateway.apps.example.test' "${url}partial-should-not-exist")" = 404
echo 'PASS: same-listener host fallback, rejected partial route, invalid TLS listener and missing Ingress Service isolation'
cat <<'MANIFEST' | kubectl -n apps apply -f -
apiVersion: lightedge.blaize.net/v1alpha1
kind: LightEdgePolicy
metadata:
  name: conflict-one
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: exact-wildcard}
  waf: {paranoiaLevel: 2}
---
apiVersion: lightedge.blaize.net/v1alpha1
kind: LightEdgePolicy
metadata:
  name: conflict-two
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: exact-wildcard}
  waf: {paranoiaLevel: 3}
MANIFEST
for i in $(seq 1 30); do
  if kubectl -n apps get lightedgepolicy conflict-one -o json | jq -e 'any(.status.conditions[]?; .type=="Accepted" and .status=="False" and .reason=="Conflicted")' >/dev/null &&
     kubectl -n apps get httproute exact-wildcard -o json | jq -e 'any(.status.parents[]?.conditions[]?; .type=="Accepted" and .status=="False")' >/dev/null; then break; fi
  test "$i" -lt 30; sleep 2
done
test "$(kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: gateway.apps.example.test' -H 'X-Mode: Canary' "$url")" = web-canary
kubectl -n apps delete lightedgepolicy conflict-two
for i in $(seq 1 30); do
  if kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: specific.wild.apps.example.test' -H 'X-Mode: Primary' "$url" 2>/dev/null | grep -qx web; then break; fi
  test "$i" -lt 30; sleep 2
done
echo 'PASS: conflicting policy withdraws affected route; other routes reconcile and corrected policy recovers'



# Ingress semantics: one DNS label, default backend for unmatched paths and
# hosts, and no changes to explicitly owned Gateway virtual hosts.
cat <<'MANIFEST' | kubectl -n apps apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wildcard-default
spec:
  ingressClassName: lightedge
  defaultBackend:
    service: {name: web, port: {number: 8080}}
  rules:
    - host: "*.ing.apps.example.test"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: web-canary, port: {number: 8080}}
    - host: fallback.apps.example.test
      http:
        paths:
          - path: /canary
            pathType: Prefix
            backend:
              service: {name: web-canary, port: {number: 8080}}
MANIFEST
for i in $(seq 1 45); do
  if kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: one.ing.apps.example.test' "$url" 2>/dev/null | grep -qx web-canary &&
     kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: two.one.ing.apps.example.test' "$url" 2>/dev/null | grep -qx web; then break; fi
  test "$i" -lt 45; sleep 2
done
test "$(kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: ing.apps.example.test' "$url")" = web
test "$(kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: fallback.apps.example.test' "$url")" = web
test "$(kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: unmatched.example.test' "$url")" = web
test "$(kubectl -n apps exec deploy/web -- curl -sS -o /dev/null -w '%{http_code}' -H 'Host: gateway.apps.example.test' "${url}not-found")" = 404
kubectl -n lightedge-system exec deploy/test-lightedge-appliance -- sh -ec 'curl -ksSf -u "admin:$ADMIN_PASSWORD" "https://127.0.0.1:9443/api/v1/site?host=%2A.ing.apps.example.test"' |
 jq -e '.site.wildcard_single==true and .site.provider=="cluster-a"' >/dev/null
echo 'PASS: Ingress single-label wildcard, global default backend and API visibility; Gateway isolation'
# Appliance rejection must not freeze the provider inventory or fall through
# from the rejected /forbidden match to the healthy broad route.
cat <<'MANIFEST' | kubectl -n apps apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: appliance-rejected
spec:
  parentRefs: [{name: lightedge, sectionName: http}]
  hostnames: ["gateway.apps.example.test"]
  rules:
    - matches: [{path: {type: PathPrefix, value: /forbidden}}]
      backendRefs: [{name: web-canary, port: 8080}]
---
apiVersion: lightedge.blaize.net/v1alpha1
kind: LightEdgePolicy
metadata:
  name: appliance-rejected
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: appliance-rejected}
  waf: {profile: unknown-profile}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: healthy-after-denial
spec:
  ingressClassName: lightedge
  rules:
    - host: healthy.apps.example.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: {service: {name: web-canary, port: {number: 8080}}}
MANIFEST
for i in $(seq 1 45); do
  if kubectl -n apps get httproute appliance-rejected -o json | jq -e 'any(.status.parents[]?.conditions[]?; .type=="Accepted" and .status=="False" and .reason=="UnsupportedValue")' >/dev/null &&
    kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: healthy.apps.example.test' "$url" 2>/dev/null | grep -qx web-canary;then break;fi
  test "$i" -lt 45;sleep 2
done
test "$(kubectl -n apps exec deploy/web -- curl -sS -o /dev/null -w '%{http_code}' -H 'Host: gateway.apps.example.test' "${url}forbidden")" = 500
kubectl -n apps patch lightedgepolicy appliance-rejected --type merge -p '{"spec":{"waf":{"profile":"strict"}}}'
for i in $(seq 1 45); do
  if kubectl -n apps get httproute appliance-rejected -o json | jq -e 'any(.status.parents[]?.conditions[]?; .type=="Accepted" and .status=="True")' >/dev/null &&
    kubectl -n apps exec deploy/web -- curl -sS -o /dev/null -w '%{http_code}' -H 'Host: gateway.apps.example.test' "${url}forbidden" 2>/dev/null | grep -qx 404;then break;fi
  test "$i" -lt 45;sleep 2
done
echo 'PASS: appliance policy denial quarantines only affected route; healthy updates and policy recovery'
# Apply Gateway-level defaults, preserving route-specific WAF profile.
cat <<'MANIFEST' | kubectl -n apps apply -f -
apiVersion: lightedge.blaize.net/v1alpha1
kind: LightEdgePolicy
metadata: {name: gateway-default}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: lightedge}
  waf: {paranoiaLevel: 3}
  maxBodySize: 2m
MANIFEST
kubectl -n apps wait --for=condition=Accepted lightedgepolicy/gateway-default --timeout=90s
for i in $(seq 1 30);do
 if kubectl -n lightedge-system exec deploy/test-lightedge-appliance -- sh -ec 'curl -ksSf -u "admin:$ADMIN_PASSWORD" "https://127.0.0.1:9443/api/v1/site?host=gateway.apps.example.test"' |
 jq -e 'any(.site.routes[];.path=="/forbidden" and .waf_pl=="3" and .max_body=="2m" and .waf_profile=="strict") and any(.site.routes[];.path=="/redirect" and .waf_pl=="3" and .max_body=="2m")' >/dev/null;then break;fi
 test "$i" -lt 30;sleep 2
done
# The inherited unapproved profile must report the Gateway policy as invalid.
kubectl -n apps patch lightedgepolicy gateway-default --type merge -p '{"spec":{"waf":{"profile":"unknown-profile"}}}'
for i in $(seq 1 45);do
 if kubectl -n apps get lightedgepolicy gateway-default -o json | jq -e 'any(.status.conditions[];.type=="Accepted" and .status=="False" and .reason=="InvalidPolicy")' >/dev/null;then break;fi
 test "$i" -lt 45;sleep 2
done
test "$(kubectl -n apps exec deploy/web -- curl -fsS -H 'Host: healthy.apps.example.test' "$url")" = web-canary
kubectl -n apps delete lightedgepolicy gateway-default
echo 'PASS: Gateway policy inheritance, per-route overrides, inherited provider rejection and independent Ingress'
echo 'PASS: Kubernetes Ingress, Gateway, policy, HTTPS, WAF and ownership reconciliation'
