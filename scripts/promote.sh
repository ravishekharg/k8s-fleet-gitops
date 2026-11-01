#!/usr/bin/env bash
# Promote a fleet commit to prod: fast-forward the `prod` branch to <commit> (default: the head of
# main), but only once every dev Application of the app is Synced to exactly that commit and
# Healthy, and has stayed that way for SOAK seconds, AND the release meets its SLO on dev during
# that soak: requests sent to it (through the dev API server's service proxy, so no port-forward)
# must fail at most SLO_MAX_ERROR_RATE and have a p99 latency under SLO_P99_MS. "Healthy" only means
# the pods run and pass their probes; a release that starts fine but serves errors is still a bad
# release. Gives up after TIMEOUT seconds and exits 1. Prod clusters follow `prod`; RollingSync then
# updates them one at a time.
#   bash scripts/promote.sh [commit]   SOAK=30 TIMEOUT=300 SLO_MAX_ERROR_RATE=0.05 SLO_P99_MS=2000
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=${KUBECONFIG:-/tmp/kubeconfig-fleet}
GIT_PORT=${GIT_PORT:-3300}
GIT_AUTH="fleet:fleet-lab-only"
SOAK=${SOAK:-30}
TIMEOUT=${TIMEOUT:-300}
SLO_MAX_ERROR_RATE=${SLO_MAX_ERROR_RATE:-0.05}
SLO_P99_MS=${SLO_P99_MS:-2000}   # measured through kubectl + the API proxy (tool overhead included)
SLO_MIN_SAMPLES=${SLO_MIN_SAMPLES:-20}
DEV_CONTEXTS=${DEV_CONTEXTS:-kind-fleet-dev}
PROBE_PATH=${PROBE_PATH:-/api/v1/namespaces/podinfo/services/podinfo:9898/proxy/}
url="http://$GIT_AUTH@localhost:$GIT_PORT/fleet/fleet.git"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
git clone -q "$url" "$work" 2>/dev/null
rev=$(git -C "$work" rev-parse --verify "${1:-origin/main}^{commit}")
if ! git -C "$work" merge-base --is-ancestor origin/prod "$rev"; then
  echo "refused: ${rev:0:7} is not ahead of prod (promotion only moves forward; roll back with a new commit)"; exit 1
fi

dev_apps() { kubectl --context kind-fleet-hub -n argocd get applications -l layer=apps,env=dev -o json; }
dev_ready() {  # every dev app: Synced to $rev and Healthy
  dev_apps | jq -e --arg rev "$rev" '(.items | length) > 0 and all(.items[];
    .status.sync.status == "Synced" and .status.health.status == "Healthy" and any(.status.sync.revisions[]?; . == $rev))' >/dev/null
}
samples=$(mktemp)                 # one line per probe: "<ok 0|1> <latency ms>", reset whenever dev isn't ready
probe() {
  local c t0 ok
  for c in $DEV_CONTEXTS; do
    t0=$(date +%s%N)
    if kubectl --context "$c" get --raw "$PROBE_PATH" >/dev/null 2>&1; then ok=1; else ok=0; fi
    echo "$ok $(( ($(date +%s%N) - t0) / 1000000 ))" >> "$samples"
  done
}
slo() {   # prints "<n> <errors> <error rate> <p99 ms>"
  sort -k2 -n "$samples" | awk '{ n++; e += ($1 == 0); lat[n] = $2 }
    END { if (!n) { print "0 0 0 0"; exit } i = int(n * 0.99); if (i < 1) i = 1; printf "%d %d %.3f %d\n", n, e, e / n, lat[i] }'
}
slo_breached() {
  read -r n errors rate p99 <<< "$(slo)"
  [ "$n" -ge "$SLO_MIN_SAMPLES" ] && awk -v r="$rate" -v m="$SLO_MAX_ERROR_RATE" -v p="$p99" -v pm="$SLO_P99_MS" \
    'BEGIN { exit !(r > m || p > pm) }'
}
start=$(date +%s); ok_since=""
while :; do
  now=$(date +%s)
  if dev_ready; then
    ok_since=${ok_since:-$now}
    for _ in 1 2 3 4 5; do probe; sleep 0.4; done
    if slo_breached; then
      read -r n errors rate p99 <<< "$(slo)"
      echo "refused: ${rev:0:7} is Healthy on dev but breaks its SLO: $errors of $n requests failed" \
        "(error rate $rate > $SLO_MAX_ERROR_RATE) or p99 ${p99} ms > ${SLO_P99_MS} ms"
      exit 1
    fi
    read -r n _ _ _ <<< "$(slo)"
    [ $(( now - ok_since )) -ge "$SOAK" ] && [ "$n" -ge "$SLO_MIN_SAMPLES" ] && break
  else ok_since=""; : > "$samples"; fi
  if [ $(( now - start )) -ge "$TIMEOUT" ]; then
    echo "refused: dev not Synced and Healthy at ${rev:0:7} for ${SOAK}s within ${TIMEOUT}s ($(dev_apps | jq -r \
      '[.items[] | "\(.metadata.name)=\(.status.sync.status)/\(.status.health.status)"] | join(" ")'))"
    exit 1
  fi
  sleep 3
done
git -C "$work" push -q "$url" "$rev:refs/heads/prod" 2>&1 | sed "s/${GIT_AUTH#*:}/***/g"
read -r n errors rate p99 <<< "$(slo)"
echo "promoted ${rev:0:7} to prod after dev was Synced and Healthy on it for ${SOAK}s, $errors of $n requests failed, p99 ${p99} ms ($(( $(date +%s) - start ))s at the gate)"
