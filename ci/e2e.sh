#!/usr/bin/env bash
# End-to-end scenarios for the velociraptor chart, against the current kube context
# (kind in CI). Covers what `ct install` cannot: multi-step lifecycles of the server
# identity (CA) and its persistence.
#
#   A  bootstrap install: identity + admin generated, helm test passes, an agent enrolls
#   B  idempotent upgrade: same CA
#   C  orgs + API clients: the sidecar creates the org and grants the client's roles through
#      the API; the client certificate Secret works for a real API query
#   D  forced certificate renewal: same CA, new certificate served, server restarted
#   E  uninstall + reinstall: identity Secret kept, same CA
#   F  existingSecret + read-only CronJob check: fails when certificates expire soon
#   G  migration config.inline -> bootstrap: identity imported, same CA and nonce
#
# Needs: helm, kubectl, jq, yq (mikefarah v4 or python-yq), openssl.
# Env: IMAGE_TAG (default: chart default), KEEP=1 to keep the namespaces.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHART="$ROOT/chart"
REL=velociraptor
NS_A=vr-e2e-a NS_F=vr-e2e-f NS_G=vr-e2e-g
WORK=$(mktemp -d)
FAILED=0
COMMON=(--set frontend.service.type=ClusterIP --set persistence.size=1Gi
        --set resources.requests.cpu=100m --set resources.requests.memory=256Mi
        --set resources.limits.memory=1Gi)
[ -n "${IMAGE_TAG:-}" ] && COMMON+=(--set "image.tag=$IMAGE_TAG")

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
check() { local msg=$1; shift; if "$@"; then pass "$msg"; else fail "$msg"; fi; }
yqr() { yq -r "$1"; }

cleanup() {
  rm -rf "$WORK"
  [ "${KEEP:-0}" = 1 ] && return
  for ns in $NS_A $NS_F $NS_G; do kubectl delete ns "$ns" --wait=false --ignore-not-found >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

dump() {  # diagnostics for a namespace
  kubectl get pods,jobs,secrets -n "$1" || true
  kubectl describe pod -n "$1" "$REL-0" 2>/dev/null | tail -25 || true
  for c in config-merge ensure-admin velociraptor state-reconciler; do
    echo "--- $c"; kubectl logs -n "$1" "$REL-0" -c "$c" --tail=30 2>/dev/null || true
  done
}

identity() { kubectl get secret "$REL-server-config" -n "$1" -o jsonpath='{.data.server\.config\.yaml}' | base64 -d; }
ca_hash()  { identity "$1" | yqr .Client.ca_certificate | sha256sum | cut -c1-16; }
fe_cert()  { identity "$1" | yqr .Frontend.certificate | sha256sum | cut -c1-16; }
admin_pw() { kubectl get secret "$REL-admin" -n "$1" -o jsonpath='{.data.password}' | base64 -d; }

install() {  # install <ns> <helm args...>
  local ns=$1; shift
  if ! helm upgrade --install "$REL" "$CHART" -n "$ns" --create-namespace "${COMMON[@]}" "$@" --wait --timeout 6m; then
    dump "$ns"; return 1
  fi
}

served_cert() {  # sha256 of the certificate served by the frontend
  kubectl run "certcheck-$RANDOM" -n "$1" --rm -i --restart=Never --quiet --image=alpine/openssl:latest --command -- \
    sh -c "echo | openssl s_client -connect $REL-frontend.$1.svc:8000 2>/dev/null | openssl x509 -outform PEM" 2>/dev/null \
    | openssl x509 -outform PEM 2>/dev/null | sha256sum | cut -c1-16
}

gui_api() {  # gui_api <ns> <path> : GET on the GUI API as the generated admin (in-cluster)
  kubectl run "gui-$RANDOM" -n "$1" --rm -i --restart=Never --quiet --image=curlimages/curl:latest \
    --labels="app.kubernetes.io/instance=$REL,app.kubernetes.io/component=test" -- \
    curl -sk -u "admin:$(admin_pw "$1")" "https://$REL-gui.$1.svc:8889$2" 2>/dev/null
}

start_agent() {  # an agent pod using the server's client config (root + writable fs: test only)
  kubectl exec -n "$1" "$REL-0" -c velociraptor -- \
    /velociraptor --nobanner --config /etc/velociraptor/server.config.yaml config client > "$WORK/client-$1.yaml"
  kubectl create secret generic e2e-agent -n "$1" --from-file=client.config.yaml="$WORK/client-$1.yaml" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl delete pod e2e-agent -n "$1" --ignore-not-found --wait >/dev/null
  kubectl apply -n "$1" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: e2e-agent}
spec:
  containers:
    - name: agent
      image: $(helm get values "$REL" -n "$1" -a -o json | jq -r '.image.registry + "/" + .image.repository + ":" + .image.tag')
      args: ["--config", "/cfg/client.config.yaml", "client", "-v"]
      securityContext: {runAsUser: 0}
      volumeMounts: [{name: cfg, mountPath: /cfg}]
  volumes: [{name: cfg, secret: {secretName: e2e-agent}}]
EOF
  kubectl wait -n "$1" --for=condition=Ready pod/e2e-agent --timeout=120s >/dev/null
}

agent_enrolled() {  # any client seen by the server
  local n
  for _ in $(seq 1 30); do
    n=$(gui_api "$1" "/api/v1/SearchClients?query=all&limit=10" | jq '[.items[]?] | length' 2>/dev/null || echo 0)
    [ "${n:-0}" -ge 1 ] && return 0; sleep 5
  done
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────────────
log "A. bootstrap install"
install $NS_A
check "identity Secret generated" test "$(kubectl get secret $REL-server-config -n $NS_A -o jsonpath='{.metadata.annotations.velociraptor\.app/source}')" = generated
check "identity Secret not owned by Helm" test -z "$(kubectl get secret $REL-server-config -n $NS_A -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
check "admin password generated" test -n "$(admin_pw $NS_A)"
check "server certificates valid ~10 years" test "$(identity $NS_A | yqr .Frontend.certificate | openssl x509 -noout -checkend $((3600*24*3000)) >/dev/null && echo ok)" = ok
check "helm test (frontend + GUI login)" helm test "$REL" -n $NS_A --timeout 3m
start_agent $NS_A
check "agent enrolled" agent_enrolled $NS_A
CA0=$(ca_hash $NS_A); FE0=$(fe_cert $NS_A)

log "B. idempotent upgrade"
install $NS_A
check "same CA after upgrade" test "$(ca_hash $NS_A)" = "$CA0"
check "same server certificate after upgrade" test "$(fe_cert $NS_A)" = "$FE0"

log "C. orgs and API clients through the API"
install $NS_A --set 'orgs.items[0].id=O01' --set 'orgs.items[0].name=E2E org' --set state.reconcilePeriodSeconds=15 \
  --set api.expose.enabled=true --set 'apiClients[0].name=e2e-client' --set 'apiClients[0].roles={api,reader}' \
  --set 'state.orgs[0].id=root' --set 'state.orgs[0].users[0].name=e2e-user' --set 'state.orgs[0].users[0].roles={reader}' \
  --set 'state.orgs[0].serverMonitoring={Server.Monitor.Health}' --set clientConfig.export.enabled=true
orgs_ok() { for _ in $(seq 1 48); do kubectl logs -n $NS_A $REL-0 -c state-reconciler 2>/dev/null | grep -q '"Granted": "e2e-client"' && return 0; sleep 5; done; return 1; }
check "org O01 reconciled" orgs_ok
check "org O01 exists" bash -c "kubectl exec -n $NS_A $REL-0 -c velociraptor -- /velociraptor --nobanner --config /etc/velociraptor/server.config.yaml query --format=jsonl \"SELECT OrgId FROM orgs()\" 2>/dev/null | grep -q O01"

state_ok() { kubectl logs -n $NS_A $REL-0 -c state-reconciler 2>/dev/null | grep 'reconcile:' | tail -1 | grep -q '"Granted": "e2e-user".*"ServerMonitoring": \[ "Server.Monitor.Health" \]'; }
check "state applied (org user role, server monitoring table)" state_ok
export_ok() { for _ in $(seq 1 24); do kubectl get secret $REL-client-root -n $NS_A >/dev/null 2>&1 && kubectl get secret $REL-client-o01 -n $NS_A >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
check "client configs exported per org" export_ok
check "exported root config is the server's (same CA)" test "$(kubectl get secret $REL-client-root -n $NS_A -o jsonpath='{.data.client\.config\.yaml}' | base64 -d | yqr .Client.ca_certificate | sha256sum | cut -c1-16)" = "$CA0"
check "API client Secret issued" test "$(kubectl get secret $REL-api-e2e-client -n $NS_A -o jsonpath='{.data}' | jq -r 'keys|join(",")')" = "api.config.yaml,ca.crt,endpoint,tls.crt,tls.key"
api_query() {  # a pod of the release (allowed by the NetworkPolicy) using the client Secret
  kubectl run "apic-$RANDOM" -n $NS_A --rm -i --restart=Never --quiet \
    --labels="app.kubernetes.io/name=velociraptor,app.kubernetes.io/instance=$REL" \
    --image="$(helm get values "$REL" -n $NS_A -a -o json | jq -r '.image.registry + "/" + .image.repository + ":" + .image.tag')" \
    --overrides='{"spec":{"containers":[{"name":"c","image":"'"$(helm get values "$REL" -n $NS_A -a -o json | jq -r '.image.registry + "/" + .image.repository + ":" + .image.tag')"'","args":["--api_config","/s/api.config.yaml","--nobanner","query","--format=jsonl","SELECT user(user=\"e2e-client\").roles AS Roles FROM scope()"],"volumeMounts":[{"name":"s","mountPath":"/s"}]}],"volumes":[{"name":"s","secret":{"secretName":"'"$REL"'-api-e2e-client"}}]}}' 2>/dev/null | grep -q '"Roles":\["api","reader"\]'
}
check "API client queries the server with its granted roles" api_query

log "D. forced certificate renewal"
POD0=$(kubectl get pod $REL-0 -n $NS_A -o jsonpath='{.metadata.uid}')
install $NS_A --set config.bootstrap.certificateValidityDays=4000 --set config.bootstrap.renewBeforeDays=3700
kubectl rollout status sts/$REL -n $NS_A --timeout=180s >/dev/null || true
check "same CA after renewal" test "$(ca_hash $NS_A)" = "$CA0"
check "new server certificate stored" test "$(fe_cert $NS_A)" != "$FE0"
check "server pod restarted" test "$(kubectl get pod $REL-0 -n $NS_A -o jsonpath='{.metadata.uid}')" != "$POD0"
FE1=$(identity $NS_A | yqr .Frontend.certificate | openssl x509 -outform PEM | sha256sum | cut -c1-16)
check "new certificate served by the frontend" test "$(served_cert $NS_A)" = "$FE1"

log "E. uninstall + reinstall keeps the identity"
helm uninstall "$REL" -n $NS_A --wait >/dev/null
check "identity Secret kept on uninstall" kubectl get secret $REL-server-config -n $NS_A
check "admin Secret kept on uninstall" kubectl get secret $REL-admin -n $NS_A
install $NS_A
check "same CA after reinstall" test "$(ca_hash $NS_A)" = "$CA0"
check "identity reused (not regenerated)" test "$(kubectl get secret $REL-server-config -n $NS_A -o jsonpath='{.metadata.annotations.velociraptor\.app/source}')" = generated
start_agent $NS_A
check "agent connects after reinstall" agent_enrolled $NS_A

log "F. existingSecret + read-only certificate check"
kubectl create ns $NS_F --dry-run=client -o yaml | kubectl apply -f - >/dev/null
identity $NS_A > "$WORK/server.config.yaml"
kubectl create secret generic external-config -n $NS_F --from-file=server.config.yaml="$WORK/server.config.yaml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
EXT0=$(kubectl get secret external-config -n $NS_F -o jsonpath='{.metadata.resourceVersion}')
install $NS_F --set config.existingSecret=external-config --set config.manageServerConfig=true \
  --set config.bootstrap.renewBeforeDays=4100
check "no identity Secret created in existingSecret mode" bash -c "! kubectl get secret $REL-server-config -n $NS_F >/dev/null 2>&1"
kubectl create job e2e-check --from=cronjob/$REL-pki-renew -n $NS_F >/dev/null
check_failed() { kubectl wait -n $NS_F --for=condition=Failed job/e2e-check --timeout=240s >/dev/null; }
check "CronJob check fails when certificates expire soon" check_failed
check "failure explains what to do" bash -c "kubectl logs -n $NS_F job/e2e-check 2>/dev/null | grep -q 'managed outside the chart'"
check "external Secret left untouched" test "$(kubectl get secret external-config -n $NS_F -o jsonpath='{.metadata.resourceVersion}')" = "$EXT0"

log "G. migration config.inline -> bootstrap"
install $NS_G --set-file config.inline="$WORK/server.config.yaml" --set config.manageServerConfig=true
check "inline Secret rendered" kubectl get secret $REL-config -n $NS_G
install $NS_G
check "identity imported from the inline Secret" test "$(kubectl get secret $REL-server-config -n $NS_G -o jsonpath='{.metadata.annotations.velociraptor\.app/source}')" = imported
check "same CA after migration" test "$(ca_hash $NS_G)" = "$CA0"
check "same nonce after migration" test "$(identity $NS_G | yqr .Client.nonce)" = "$(yqr .Client.nonce < "$WORK/server.config.yaml")"
check "inline Secret removed by Helm" bash -c "! kubectl get secret $REL-config -n $NS_G >/dev/null 2>&1"
check "helm test after migration" helm test "$REL" -n $NS_G --timeout 3m

echo
if [ "$FAILED" = 0 ]; then echo "e2e: ALL PASSED"; else echo "e2e: FAILURES"; exit 1; fi
