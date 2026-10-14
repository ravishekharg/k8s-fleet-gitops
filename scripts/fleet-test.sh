#!/usr/bin/env bash
# Fleet behaviour, checked live against the clusters from scripts/up.sh. Each check prints PASS
# or FAIL with a measured time; the script exits 1 if any check fails.
#   1. bootstrap      every managed cluster gets the platform layer and the app from git
#   2. governance     the same violating pod: rejected on prod (Enforce), admitted but reported on dev (Audit)
#   3. drift          a NetworkPolicy deleted by hand on a cluster is put back by Argo CD
#   4. onboarding     labelling a registered cluster fleet/managed=true is all it takes
#   5. waves          a new version reaches dev first, then each prod cluster one at a time
#   6. halt           a release that can't start on dev never reaches prod; reverting recovers dev
set -uo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=${KUBECONFIG:-/tmp/kubeconfig-fleet}
hub() { kubectl --context kind-fleet-hub "$@"; }
on() { local c=$1; shift; kubectl --context "kind-fleet-$c" "$@"; }
FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
ts() { date +%s; }

app_ok() {  # app_ok <app>: Synced and Healthy
  [ "$(hub -n argocd get application "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)" = "Synced/Healthy" ]
}
cluster_ok() {  # cluster_ok <cluster>: all four fleet apps Synced/Healthy
  for a in kyverno policies baseline podinfo; do app_ok "$a-$1" || return 1; done
}
wait_until() {  # wait_until <timeout> <command...>: seconds taken, or empty on timeout
  local timeout=$1 start; shift; start=$(ts)
  while ! "$@" >/dev/null 2>&1; do [ $(( $(ts) - start )) -ge "$timeout" ] && return 1; sleep 3; done
  echo $(( $(ts) - start ))
}
image_on() { on "$1" -n podinfo get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null; }
rolled_out() {  # rolled_out <cluster> <tag>: the deployment runs <tag> on all replicas, rollout complete
  [ "$(image_on "$1")" = "ghcr.io/stefanprodan/podinfo:$2" ] && on "$1" -n podinfo rollout status deploy/podinfo --timeout=1s
}
set_tag() {  # commit a new image tag (what merging a release PR does)
  sed -i "s/^  tag: .*/  tag: $1/" fleet/apps/podinfo/values.yaml
  bash scripts/push-fleet.sh "podinfo $1" >/dev/null
}

echo "== 1. bootstrap"
for c in dev prod-eu; do
  if t=$(wait_until 900 cluster_ok "$c"); then
    pass "$c: kyverno, policies, baseline and podinfo Synced/Healthy ($(( $(ts) - $(cat /tmp/fleet-bootstrapped-at) )) s after the root app)"
  else fail "$c not fully synced after 15 min"; hub -n argocd get applications; fi
done
if [ -z "$(hub -n argocd get applications -o name | grep prod-us)" ]; then pass "prod-us (registered, not labelled managed) received nothing"
else fail "prod-us got applications without being labelled"; fi

echo "== 2. governance"
violator() {  # a pod Pod Security 'baseline' allows but fleet policy forbids: :latest, no requests/limits
  cat <<EOF | on "$1" apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata: { name: policy-probe, namespace: podinfo }
spec: { containers: [{ name: c, image: "nginx:latest" }] }
EOF
}
out=$(violator prod-eu)
if echo "$out" | grep -q "disallow-latest-tag"; then pass "prod-eu rejected the pod: $(echo "$out" | grep -oE 'disallow-latest-tag[^.]*' | head -1 | cut -c1-90)"
else fail "prod-eu admitted a :latest pod with no limits: $out"; on prod-eu -n podinfo delete pod policy-probe --ignore-not-found >/dev/null; fi
out=$(violator dev)
if echo "$out" | grep -q "created"; then
  if t=$(wait_until 180 sh -c "kubectl --context kind-fleet-dev -n podinfo get policyreports -o json | grep -q '\"policy\": \"disallow-latest-tag\"'"); then
    pass "dev admitted it (Audit) and reported the violations in a PolicyReport within ${t}s"
  else fail "dev admitted the pod but no PolicyReport appeared"; fi
else fail "dev rejected the pod in Audit mode: $out"; fi
on dev -n podinfo delete pod policy-probe --ignore-not-found --wait=false >/dev/null

echo "== 3. drift"
on prod-eu -n podinfo delete networkpolicy default-deny-ingress >/dev/null
if t=$(wait_until 120 on prod-eu -n podinfo get networkpolicy default-deny-ingress); then pass "default-deny NetworkPolicy deleted by hand on prod-eu: restored by Argo CD in ${t}s"
else fail "deleted NetworkPolicy not restored within 120 s"; fi

echo "== 4. onboarding"
hub -n argocd label secret cluster-prod-us fleet/managed=true --overwrite >/dev/null
if t=$(wait_until 900 cluster_ok prod-us); then pass "prod-us labelled fleet/managed=true: fully compliant in ${t}s, nothing else done"
else fail "prod-us not compliant 15 min after labelling"; fi
out=$(violator prod-us)
echo "$out" | grep -q "disallow-latest-tag" && pass "prod-us enforces fleet policy" || { fail "prod-us does not enforce: $out"; on prod-us -n podinfo delete pod policy-probe --ignore-not-found >/dev/null; }

echo "== 5. waves: release 6.7.1"
set_tag 6.7.1
declare -A done_at
start=$(ts)
while [ ${#done_at[@]} -lt 3 ] && [ $(( $(ts) - start )) -lt 900 ]; do
  for c in dev prod-eu prod-us; do
    [ -z "${done_at[$c]:-}" ] && rolled_out "$c" 6.7.1 >/dev/null 2>&1 && done_at[$c]=$(( $(ts) - start )) && echo "   ${done_at[$c]}s  $c on 6.7.1"
  done
  sleep 3
done
if [ ${#done_at[@]} -eq 3 ]; then
  first_prod=$(( done_at[prod-eu] < done_at[prod-us] ? done_at[prod-eu] : done_at[prod-us] ))
  last_prod=$(( done_at[prod-eu] > done_at[prod-us] ? done_at[prod-eu] : done_at[prod-us] ))
  if [ "${done_at[dev]}" -lt "$first_prod" ] && [ $(( last_prod - first_prod )) -ge 6 ]; then
    pass "dev (${done_at[dev]}s) before prod, prod clusters one after the other (${first_prod}s, ${last_prod}s)"
  else fail "wave order wrong: dev ${done_at[dev]}s, prod ${first_prod}s / ${last_prod}s"; fi
else fail "release did not reach all clusters in 15 min (${!done_at[*]})"; fi

echo "== 6. halt: release 6.7.1-broken (tag doesn't exist)"
set_tag 6.7.1-broken
if t=$(wait_until 300 sh -c "kubectl --context kind-fleet-dev -n podinfo get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q broken"); then
  echo "   ${t}s  dev got the broken release (old pod keeps serving: maxUnavailable 0 at 1 replica)"
  sleep 150
  if [ "$(image_on prod-eu)" = "ghcr.io/stefanprodan/podinfo:6.7.1" ] && [ "$(image_on prod-us)" = "ghcr.io/stefanprodan/podinfo:6.7.1" ]; then
    pass "150 s later prod-eu and prod-us still run 6.7.1: the wave stopped at dev ($(hub -n argocd get application podinfo-dev -o jsonpath='{.status.health.status}') there)"
  else fail "broken release reached prod: $(image_on prod-eu), $(image_on prod-us)"; fi
else fail "dev never received the broken release"; fi
set_tag 6.7.1
if t=$(wait_until 300 rolled_out dev 6.7.1); then pass "revert in git: dev back on 6.7.1 in ${t}s"
else fail "dev did not recover after the revert"; fi

echo
[ $FAILS -eq 0 ] && echo "all fleet checks passed" || echo "$FAILS check(s) failed"
exit $(( FAILS > 0 ))
