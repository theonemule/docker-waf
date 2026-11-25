#!/usr/bin/env bash
# Runs only inside the isolated QEMU runner container.
set -euo pipefail
umask 077
cd /lab
mkdir -p /lab/evidence /lab/private
exec > >(tee -a /lab/evidence/run.log) 2>&1
export KUBECONFIG=/lab/private/kubeconfig
export HELM_CACHE_HOME=/lab/private/helm-cache HELM_CONFIG_HOME=/lab/private/helm-config HELM_DATA_HOME=/lab/private/helm-data
ssh-keygen -q -t ed25519 -N '' -f /lab/private/id
pub=$(cat /lab/private/id.pub)
root_hash=$(openssl rand -hex 32 | openssl passwd -6 -stdin)
pids=()
k(){ /lab/input/kubectl "$@"; }
h(){ /lab/input/helm "$@"; }
ssh_args=(-i /lab/private/id -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/lab/private/known_hosts -o ConnectTimeout=5)
remote(){ local n="$1";shift;ssh "${ssh_args[@]}" -p "$((2200+n))" root@127.0.0.1 "$@"; }
copy(){ local n="$1" src="$2" dst="$3";scp -q "${ssh_args[@]}" -P "$((2200+n))" "$src" "root@127.0.0.1:$dst"; }
cleanup(){
 rc=$?;set +e
 if [[ -f "$KUBECONFIG" ]];then
   k --request-timeout=15s get nodes -o wide >evidence/nodes.txt 2>&1
   k --request-timeout=15s get pods -A -o wide >evidence/pods.txt 2>&1
   k --request-timeout=15s get gateway,httproute,grpcroute,tcproute,udproute,tlsroute,backendtlspolicy,ingress -A -o yaml >evidence/routes.yaml 2>&1
   k --request-timeout=15s -n lightedge-system logs deploy/test-lightedge --tail=100 >evidence/controller.log 2>&1
   for i in 0 1;do
     k --request-timeout=15s -n lightedge-system logs "test-lightedge-appliance-$i" -c appliance --tail=100 >"evidence/appliance-$i.log" 2>&1
     k --request-timeout=15s -n lightedge-system exec "test-lightedge-appliance-$i" -c appliance -- sh -c 'tail -500 /data/logs/streams.jsonl 2>/dev/null || true' >"evidence/appliance-$i-streams.jsonl" 2>&1
     k --request-timeout=15s -n lightedge-system exec "test-lightedge-appliance-$i" -c appliance -- sh -c 'tail -100 /data/logs/ha-worker.log 2>/dev/null || true; jq -c "{revision,digest}" /data/.liteedge-ha-applied.json /ha/current.json' >"evidence/appliance-$i-ha.txt" 2>&1
   done
   k --request-timeout=15s get events -A --sort-by=.metadata.creationTimestamp >evidence/events.txt 2>&1
 fi
 for n in 1 2 3;do
   timeout 12 ssh "${ssh_args[@]}" -p "$((2200+n))" root@127.0.0.1 "cat /var/tmp/lightedge-memory.log" >"evidence/node$n-memory.log" 2>&1 || true
   remote "$n" 'tail -n 100 /var/log/k3s.log 2>/dev/null || true; uname -a; cat /etc/alpine-release; free -m' >"evidence/node$n-runtime.txt" 2>&1 || true
 done
 for pid in "${pids[@]}";do kill "$pid" 2>/dev/null||true;done
 # Wait for VM children only; the process-substitution logger drains on exit.
 for pid in "${pids[@]}";do wait "$pid" 2>/dev/null||true;done
 echo "$rc" >evidence/result.exit
 echo "QEMU integration exit=$rc; VM processes stopped"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
base=/lab/input/alpine.qcow2
accel=tcg
cpu=max
if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]];then accel=kvm;cpu=host;fi
worker_mem=${QEMU_WORKER_MEM_MB:-1536};control_mem=${QEMU_CONTROL_MEM_MB:-2048}
[[ "$worker_mem" =~ ^[0-9]+$ && "$control_mem" =~ ^[0-9]+$ ]]
((worker_mem>=1024 && worker_mem<=4096 && control_mem>=1536 && control_mem<=4096))
echo "QEMU accelerator=$accel; control plane $control_mem MiB; workers $worker_mem MiB each; 1 vCPU per node"
for n in 1 2 3;do
 name=le-node$n
 mkdir -p "private/$name"
 qemu-img create -q -f qcow2 -F qcow2 -b "$base" "private/$name/disk.qcow2" 12G
 cat >"private/$name/user-data" <<YAML
#cloud-config
hostname: $name
preserve_hostname: false
disable_root: false
ssh_pwauth: false
users:
  - name: root
    ssh_authorized_keys:
      - $pub
    lock_passwd: false
    hashed_passwd: "$root_hash"
write_files:
  - path: /root/.ssh/authorized_keys
    permissions: '0600'
    content: |
      $pub
  - path: /etc/ssh/sshd_config.d/90-lab.conf
    content: |
      PermitRootLogin prohibit-password
      PasswordAuthentication no
  - path: /etc/local.d/10-lab-net.start
    permissions: '0755'
    content: |
      #!/bin/sh
      ip link set eth1 up
      ip addr replace 192.168.77.$((10+n))/24 dev eth1
runcmd:
  - [sh, -c, 'chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys']
  - [sh, /etc/local.d/10-lab-net.start]
  - [rc-update, add, local, default]
  - [sh, -c, 'printf "rc_cgroup_mode=unified\n" >> /etc/rc.conf']
  - [rc-update, add, cgroups, boot]
  - [rc-service, cgroups, start]
  - [sh, -c, 'modprobe overlay; modprobe br_netfilter; modprobe vxlan; sysctl -w net.ipv4.ip_forward=1']
  - [sh, -c, 'apk add --no-cache iptables ip6tables iproute2 nfs-utils curl ca-certificates']
  - [touch, /var/tmp/lightedge-vm-ready]
YAML
 printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$name" >"private/$name/meta-data"
 genisoimage -quiet -output "private/$name/seed.iso" -volid cidata -joliet -rock "private/$name/user-data" "private/$name/meta-data"
 # Private multicast ethernet bus inside the runner's network namespace.
 mem=$worker_mem;[[ $n != 1 ]]||mem=$control_mem
 forwards="hostfwd=tcp:127.0.0.1:$((2200+n))-:22,hostfwd=tcp:127.0.0.1:$((28080+n))-:30080,hostfwd=tcp:127.0.0.1:$((28440+n))-:30443,hostfwd=tcp:127.0.0.1:$((28180+n))-:30081,hostfwd=tcp:127.0.0.1:$((28540+n))-:30444,hostfwd=tcp:127.0.0.1:$((29000+n))-:30900,hostfwd=udp:127.0.0.1:$((29100+n))-:30901,hostfwd=tcp:127.0.0.1:$((29440+n))-:30944"
 [[ $n != 1 ]]||forwards="$forwards,hostfwd=tcp:127.0.0.1:26443-:6443"
 qemu-system-x86_64 -machine q35,accel="$accel" -cpu "$cpu" -smp 1 -m "$mem" \
   -display none -monitor none -serial "file:/lab/evidence/$name.serial.log" \
   -drive "file=/lab/private/$name/disk.qcow2,if=virtio,format=qcow2" \
   -drive "file=/lab/private/$name/seed.iso,media=cdrom,readonly=on" \
   -netdev "user,id=nat,$forwards" -device "virtio-net-pci,netdev=nat,mac=52:54:00:77:00:0$n" \
   -netdev "socket,id=lan,mcast=230.77.77.77:17777" -device "virtio-net-pci,netdev=lan,mac=52:54:00:77:01:0$n" \
   -no-reboot >"evidence/$name.qemu.log" 2>&1 &
 pids+=("$!")
done
wait_vm(){ local n="$1";for _ in $(seq 1 180);do if remote "$n" 'test -f /var/tmp/lightedge-vm-ready' >/dev/null 2>&1;then echo "VM $n ready";return 0;fi;sleep 3;done;echo "VM $n boot/cloud-init timed out";return 1; }
for n in 1 2 3;do wait_vm "$n";done
for n in 1 2 3;do
 copy "$n" /lab/input/memory-sampler.sh /var/tmp/lightedge-memory-sampler.sh
 remote "$n" 'nohup sh /var/tmp/lightedge-memory-sampler.sh >/var/tmp/lightedge-memory.log 2>&1 </dev/null &'
done
remote 1 'ping -c 2 -W 2 192.168.77.12 && ping -c 2 -W 2 192.168.77.13'
prepare(){ local n="$1"
 remote "$n" 'mkdir -p /var/lib/rancher/k3s/agent/images'
 copy "$n" /lab/input/k3s /usr/local/bin/k3s
 copy "$n" /lab/input/k3s-airgap-images-amd64.tar.zst /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst
 copy "$n" /lab/input/lightedge-images.tar /var/lib/rancher/k3s/agent/images/lightedge-images.tar
 remote "$n" 'chmod 0755 /usr/local/bin/k3s; k3s --version; uname -a; cat /etc/alpine-release; test -e /sys/fs/cgroup/cgroup.controllers'
}
jobs=();for n in 1 2 3;do prepare "$n" >"evidence/node$n-prepare.log" 2>&1 & jobs+=("$!");done
for job in "${jobs[@]}";do wait "$job";done
token=$(openssl rand -hex 32)
# Pass private token via stdin, not log or command argument.
for n in 1 2 3;do printf '%s' "$token" | remote "$n" 'umask 077; mkdir -p /etc/rancher/k3s; cat >/etc/rancher/k3s/token';done
remote 1 'nohup k3s server --token-file /etc/rancher/k3s/token --node-ip 192.168.77.11 --advertise-address 192.168.77.11 --tls-san 127.0.0.1 --flannel-iface eth1 --cluster-cidr 10.42.0.0/16 --service-cidr 10.43.0.0/16 --disable traefik --disable servicelb --disable metrics-server --disable-network-policy --node-taint node-role.kubernetes.io/control-plane=true:NoSchedule >/var/log/k3s.log 2>&1 </dev/null &'
for i in $(seq 1 180);do if remote 1 'test -s /etc/rancher/k3s/k3s.yaml' 2>/dev/null;then break;fi;[[ $i -lt 180 ]];sleep 2;done
remote 1 'cat /etc/rancher/k3s/k3s.yaml' | sed 's/127.0.0.1:6443/127.0.0.1:26443/' >"$KUBECONFIG"
for n in 2 3;do remote "$n" "nohup k3s agent --server https://192.168.77.11:6443 --token-file /etc/rancher/k3s/token --node-ip 192.168.77.$((10+n)) --flannel-iface eth1 >/var/log/k3s.log 2>&1 </dev/null &";done
for i in $(seq 1 180);do
 if [[ "$(k get nodes -o json 2>/dev/null | jq -r '[.items[]|select(any(.status.conditions[];.type=="Ready" and .status=="True"))]|length' || true)" == 3 ]];then break;fi
 [[ $i -lt 180 ]];sleep 3
done
k get nodes -o wide
echo 'PASS three independent QEMU guest kernels joined the Kubernetes cluster'
for n in 2 3;do k label node "le-node$n" lightedge-lab/worker=true;done
# A dedicated, real NFSv4 export inside the first VM. No host filesystem mount.
remote 1 'mkdir -p /srv/lightedge-ha; chown 10001:10001 /srv/lightedge-ha; chmod 700 /srv/lightedge-ha; printf "/srv/lightedge-ha 192.168.77.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=0)\n" >/etc/exports; rc-service rpcbind start || exit 1; for attempt in 1 2 3 4 5; do rc-service nfs start || true; if [ "$(cat /proc/fs/nfsd/threads 2>/dev/null || echo 0)" -gt 0 ]; then break; fi; sleep 2; done; test "$(cat /proc/fs/nfsd/threads)" -gt 0 || exit 1; exportfs -v'
printf '%s' '{"cluster_id":"qemu-lab","bootstrap_node":"test-lightedge-appliance-0","members":{"test-lightedge-appliance-0":"test-lightedge-appliance-0.test-lightedge-appliance-members.lightedge-system.svc","test-lightedge-appliance-1":"test-lightedge-appliance-1.test-lightedge-appliance-members.lightedge-system.svc"}}' | remote 1 'umask 077;cat >/srv/lightedge-ha/cluster.json;chown 10001:10001 /srv/lightedge-ha/cluster.json'
k apply --server-side -f /lab/input/gateway-api.yaml
k wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io crd/grpcroutes.gateway.networking.k8s.io crd/tcproutes.gateway.networking.k8s.io crd/udproutes.gateway.networking.k8s.io crd/tlsroutes.gateway.networking.k8s.io crd/backendtlspolicies.gateway.networking.k8s.io --timeout=120s
k create namespace lightedge-system
k apply -f /lab/input/ha-pv.yaml
openssl rand -hex 32 >private/token;openssl rand -hex 24 >private/password;openssl rand -hex 32 >private/key
dns=test-lightedge-appliance.lightedge-system.svc
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout private/admin.key -out private/admin.crt -subj "/CN=$dns" -addext "subjectAltName=DNS:$dns" >/dev/null 2>&1
hash=$(tr -d '\n' <private/token | sha256sum|cut -d' ' -f1)
jq -n --arg hash "$hash" '{token_sha256:$hash,host_suffixes:["apps.example.test"],backend_cidrs:["10.42.0.0/16","10.43.0.0/16"],min_waf_pl:1,allow_grpc:true,allow_stream:true,allow_backend_tls:true,extra_http_ports:[8081],extra_https_ports:[8443],stream_ports:{tcp:[9000],udp:[9001],tls:[9444]}}' >private/provider.json
k -n lightedge-system create secret generic lightedge-provider --from-file=token=private/token --from-file=ca.crt=private/admin.crt --from-file=provider.json=private/provider.json
k -n lightedge-system create secret tls lightedge-admin-tls --cert=private/admin.crt --key=private/admin.key
k -n lightedge-system create secret generic lightedge-admin --from-file=password=private/password
k -n lightedge-system create secret generic lightedge-ha-key --from-file=key=private/key
h upgrade --install test /lab/input/chart -n lightedge-system -f /lab/input/values.yaml --set "appliance.image=$EDGE_IMAGE" --set "image.repository=${CONTROLLER_IMAGE%:*}" --set "image.tag=${CONTROLLER_IMAGE##*:}" 
# Map each manifest-provisioned public listener to a deterministic external port.
service=test-lightedge-appliance-public
for mapping in 80:30080 443:30443 8081:30081 8443:30444 9000:30900 9001:30901 9444:30944;do
 public=${mapping%:*};nodeport=${mapping#*:}
 index=$(k -n lightedge-system get svc "$service" -o json|jq -er --argjson p "$public" '.spec.ports|to_entries[]|select(.value.port==$p)|.key')
 k -n lightedge-system patch svc "$service" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/$index/nodePort\",\"value\":$nodeport}]"
done
k -n lightedge-system rollout status statefulset/test-lightedge-appliance --timeout=300s
k -n lightedge-system rollout status deployment/test-lightedge --timeout=300s
k -n lightedge-system get pods -o wide
nodes=$(k -n lightedge-system get pods -l app.kubernetes.io/name=lightedge-appliance -o json |jq '[.items[].spec.nodeName]|unique|length')
[[ $nodes == 2 ]]
echo 'PASS two LightEdge appliances on distinct QEMU worker VMs using real NFS RWX'
k create namespace apps
# Separate trust identities prove TLS termination vs unchanged passthrough.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout private/frontend.key -out private/frontend.crt -subj /CN=hello.apps.example.test -addext 'subjectAltName=DNS:hello.apps.example.test,DNS:extra.apps.example.test,DNS:secure.apps.example.test,DNS:grpc.apps.example.test,DNS:ingress-tls.apps.example.test' -addext 'basicConstraints=critical,CA:TRUE' >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout private/backend.key -out private/backend.crt -subj /CN=backend.apps.example.test -addext 'subjectAltName=DNS:backend.apps.example.test,DNS:passthrough.apps.example.test' -addext 'basicConstraints=critical,CA:TRUE' >/dev/null 2>&1
k -n apps create secret tls frontend-cert --cert=private/frontend.crt --key=private/frontend.key
k -n apps create secret tls backend-cert --cert=private/backend.crt --key=private/backend.key
k -n apps create configmap frontend-ca --from-file=ca.crt=private/frontend.crt
k -n apps create configmap backend-ca --from-file=ca.crt=private/backend.crt
sed "s|@FIXTURE_IMAGE@|$FIXTURE_IMAGE|g" /lab/input/hello.yaml | k -n apps apply -f -
source /lab/input/matrix.sh
k -n apps rollout status deployment/hello --timeout=240s
k -n apps wait --for=condition=Programmed gateway/edge --timeout=180s
wait_routes
wait_members 2
for i in $(seq 1 90);do
 if k -n apps get httproute hello -o json | jq -e 'any(.status.parents[]?.conditions[]?;.type=="Programmed" and .status=="True")' >/dev/null;then break;fi
 [[ $i -lt 90 ]];sleep 2
done
request(){ curl -fsS --max-time 5 -H 'Host: hello.apps.example.test' "http://127.0.0.1:$((28080+$1))/"; }
for i in $(seq 1 90);do if request 2 >/dev/null 2>&1 && request 3 >/dev/null 2>&1;then break;fi;[[ $i -lt 90 ]];sleep 2;done
: >evidence/requests.jsonl
for i in $(seq 1 40);do request "$((2+i%2))" >>evidence/requests.jsonl;echo >>evidence/requests.jsonl;done
jq -s -e 'all(.[];.message=="Hello World") and ([.[].pod]|unique|length)==2 and ([.[].node]|unique|length)==2' evidence/requests.jsonl
jq -s 'group_by(.node)|map({node:.[0].node,pod:.[0].pod,requests:length})' evidence/requests.jsonl |tee evidence/distribution.json
# Test each appliance directly, proving both have the route and reach both backends.
for n in 0 1;do
 k -n lightedge-system exec "test-lightedge-appliance-$n" -- sh -ec 'for i in $(seq 1 12);do curl -fsS -H "Host: hello.apps.example.test" http://127.0.0.1:8080/;echo;done' >"evidence/appliance-$n-requests.jsonl"
 jq -s -e '([.[].pod]|unique|length)==2' "evidence/appliance-$n-requests.jsonl"
done
echo 'PASS external NodePort requests and both native appliance instances load-balance across two backend pods'
# Confirm actual WAF enforcement from outside the cluster.
code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -H 'Host: hello.apps.example.test' 'http://127.0.0.1:28082/?q=%3Cscript%3Ealert(1)%3C/script%3E')
[[ "$code" == 403 ]]
echo 'PASS public WAF rejection'
matrix baseline 2 12
negative_cases
wait_members 2
k -n lightedge-system scale statefulset/test-lightedge-appliance --replicas=1
k -n lightedge-system wait --for=delete pod/test-lightedge-appliance-1 --timeout=180s
for i in $(seq 1 12);do request "$((2+i%2))" >/dev/null;done
echo 'PASS public traffic survives appliance removal'
matrix single-replica 1 8
k -n apps patch httproute hello --type=json -p '[{"op":"add","path":"/spec/rules/0/filters","value":[{"type":"ResponseHeaderModifier","responseHeaderModifier":{"set":[{"name":"X-Lab-Revision","value":"two"}]}}]}]'
for i in $(seq 1 90);do if curl -fsS --max-time 5 -D - -o /dev/null -H 'Host: hello.apps.example.test' http://127.0.0.1:28082/ |tr -d '\r'|grep -qi '^X-Lab-Revision: two$';then break;fi;[[ $i -lt 90 ]];sleep 2;done
k -n lightedge-system scale statefulset/test-lightedge-appliance --replicas=2
k -n lightedge-system rollout status statefulset/test-lightedge-appliance --timeout=240s
for n in 0 1;do
 k -n lightedge-system exec "test-lightedge-appliance-$n" -- sh -ec 'curl -fsS -D - -o /dev/null -H "Host: hello.apps.example.test" http://127.0.0.1:8080/ | tr -d "\r" | grep -i "^X-Lab-Revision: two$"; jq -c "{revision,digest}" /data/.liteedge-ha-applied.json' |tee "evidence/appliance-$n-rejoin.txt"
done
diff <(tail -1 evidence/appliance-0-rejoin.txt) <(tail -1 evidence/appliance-1-rejoin.txt)
echo 'PASS update while replica absent, rejoin and identical signed revision'
matrix rejoined 2 8
echo 'PASS QEMU FULL INTEGRATION'
