#!/usr/bin/env bash
# Fleet behaviour, checked live against the clusters from scripts/up.sh. Each check prints PASS
# or FAIL with a measured time; the script exits 1 if any check fails.
#   1. bootstrap      every managed cluster gets the platform layer and the app from git
#   2. governance     the same violating pod: rejected on prod (Enforce), admitted but reported on dev (Audit)
#   3. drift          a NetworkPolicy deleted by hand on a cluster is put back by Argo CD
#   4. onboarding     labelling a registered cluster fleet/managed=true is all it takes
#   5. release        a merge reaches dev only; promotion passes the gate; prod updates one cluster at a time
#   6. halt           a release that can't start on dev is refused at the gate and never reaches prod
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
set_tag() {  # commit a new image tag (what merging a release PR does); REV = the commit
  sed -i "s/^  tag: .*/  tag: $1/" fleet/apps/podinfo/values.yaml
  REV=$(bash scripts/push-fleet.sh "podinfo $1" | awk '/^   pushed: / { print $2 }')
}
appset_status() {  # appset_status <jq filter>: over the podinfo ApplicationSet's progressive sync status
  hub -n argocd get applicationset podinfo -o json | jq -r --arg rev "$REV" "$1"
}
wave_done() {  # the ApplicationSet controller reports all three podinfo apps Healthy at commit REV
  [ "$(appset_status '[.status.applicationStatus[] | select(.status == "Healthy" and any(.targetRevisions[]; startswith($rev)))] | length')" = 3 ]
}
healthy_at() {  # healthy_at <cluster>: when the controller marked it Healthy (epoch s)
  date -d "$(appset_status ".status.applicationStatus[] | select(.application == \"podinfo-$1\") | .lastTransitionTime")" +%s
}
synced_at() {  # synced_at <cluster> <tag>: when the sync created the ReplicaSet for <tag> (epoch s)
  date -d "$(on "$1" -n podinfo get rs -o json | jq -r --arg img "ghcr.io/stefanprodan/podinfo:$2"     '[.items[] | select(.spec.template.spec.containers[0].image == $img) | .metadata.creationTimestamp] | min')" +%s
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
violator() {  # a pod Pod Security 'baseline' allows but fleet policy forbids: :latest, no memory limit
  # (it has requests: without them the namespace ResourceQuota rejects it before Audit can report it)
  cat <<EOF | on "$1" apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata: { name: policy-probe, namespace: podinfo }
spec: { containers: [{ name: c, image: "nginx:latest", resources: { requests: { cpu: 10m, memory: 16Mi } } }] }
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
enforces() {  # the probe pod is rejected by fleet policy (policies can lag "Healthy" by a few seconds)
  violator "$1" | grep -q "disallow-latest-tag" && return 0
  on "$1" -n podinfo delete pod policy-probe --ignore-not-found --wait=false >/dev/null; return 1
}
if t=$(wait_until 90 enforces prod-us); then pass "prod-us enforces fleet policy (${t}s after it reported compliant)"
else fail "prod-us does not enforce fleet policy 90 s after reporting compliant"; fi

echo "== 5. release 6.7.1: dev from main, prod only through the promotion gate"
set_tag 6.7.1
if t=$(wait_until 300 rolled_out dev 6.7.1); then pass "merged to main: dev on 6.7.1 in ${t}s"
else fail "dev not on 6.7.1 5 min after the merge"; fi
if [ "$(image_on prod-eu)" = "ghcr.io/stefanprodan/podinfo:6.7.0" ] && [ "$(image_on prod-us)" = "ghcr.io/stefanprodan/podinfo:6.7.0" ]; then
  pass "prod-eu and prod-us still on 6.7.0: prod follows the prod branch, not main"
else fail "prod changed before promotion: $(image_on prod-eu), $(image_on prod-us)"; fi
if out=$(bash scripts/promote.sh "$REV" 2>&1); then pass "gate: $(echo "$out" | tail -1)"
else fail "gate refused a healthy release: $out"; fi
# Order inside prod, from timestamps the clusters record (all kind nodes share a clock): when each
# sync created the new ReplicaSet, and when the controller saw each app Healthy.
promoted=$(ts)
if t=$(wait_until 600 wave_done); then
  declare -A synced=() healthy=()
  for c in prod-eu prod-us; do synced[$c]=$(( $(synced_at "$c" 6.7.1) - promoted )); healthy[$c]=$(( $(healthy_at "$c") - promoted )); done
  if [ "${synced[prod-eu]}" -le "${synced[prod-us]}" ]; then p1=prod-eu p2=prod-us; else p1=prod-us p2=prod-eu; fi
  echo "   after promotion: $p1 synced ${synced[$p1]}s, Healthy ${healthy[$p1]}s / $p2 synced ${synced[$p2]}s, Healthy ${healthy[$p2]}s"
  if [ "${healthy[$p1]}" -le "${synced[$p2]}" ]; then pass "prod updated one cluster at a time: $p2 started only after $p1 was Healthy (${t}s in all)"
  else fail "prod clusters updated in parallel (times above)"; fi
else fail "prod not on 6.7.1 10 min after promotion: $(appset_status '[.status.applicationStatus[] | "\(.application)=\(.status)"] | join(" ")')"; fi

echo "== 6. halt: release 6.7.1-broken (tag doesn't exist)"
set_tag 6.7.1-broken
if t=$(wait_until 300 sh -c "kubectl --context kind-fleet-dev -n podinfo get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q broken"); then
  echo "   ${t}s  dev got the broken release (old pod keeps serving: maxUnavailable 0 at 1 replica)"
  if out=$(TIMEOUT=120 bash scripts/promote.sh "$REV" 2>&1); then fail "the gate promoted a release that can't start on dev: $out"
  else pass "gate: $(echo "$out" | tail -1 | cut -c1-160)"; fi
  if [ "$(image_on prod-eu)" = "ghcr.io/stefanprodan/podinfo:6.7.1" ] && [ "$(image_on prod-us)" = "ghcr.io/stefanprodan/podinfo:6.7.1" ]; then
    pass "prod-eu and prod-us still run 6.7.1"
  else fail "broken release reached prod: $(image_on prod-eu), $(image_on prod-us)"; fi
else fail "dev never received the broken release"; fi
set_tag 6.7.1
if t=$(wait_until 300 rolled_out dev 6.7.1); then pass "revert in git: dev back on 6.7.1 in ${t}s"
else fail "dev did not recover after the revert"; fi

echo
[ $FAILS -eq 0 ] && echo "all fleet checks passed" || echo "$FAILS check(s) failed"
exit $(( FAILS > 0 ))
