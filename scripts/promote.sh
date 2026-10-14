#!/usr/bin/env bash
# Promote a fleet commit to prod: fast-forward the `prod` branch to <commit> (default: the head of
# main), but only once every dev Application of the app is Synced to exactly that commit and
# Healthy, and has stayed that way for SOAK seconds. Gives up after TIMEOUT seconds and exits 1.
# Prod clusters follow `prod`; RollingSync then updates them one at a time.
#   bash scripts/promote.sh [commit]          SOAK=30 TIMEOUT=300
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=${KUBECONFIG:-/tmp/kubeconfig-fleet}
GIT_PORT=${GIT_PORT:-3300}
GIT_AUTH="fleet:fleet-lab-only"
SOAK=${SOAK:-30}
TIMEOUT=${TIMEOUT:-300}
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
start=$(date +%s); ok_since=""
while :; do
  now=$(date +%s)
  if dev_ready; then
    ok_since=${ok_since:-$now}
    [ $(( now - ok_since )) -ge "$SOAK" ] && break
  else ok_since=""; fi
  if [ $(( now - start )) -ge "$TIMEOUT" ]; then
    echo "refused: dev not Synced and Healthy at ${rev:0:7} for ${SOAK}s within ${TIMEOUT}s ($(dev_apps | jq -r \
      '[.items[] | "\(.metadata.name)=\(.status.sync.status)/\(.status.health.status)"] | join(" ")'))"
    exit 1
  fi
  sleep 3
done
git -C "$work" push -q "$url" "$rev:refs/heads/prod" 2>&1 | sed "s/${GIT_AUTH#*:}/***/g"
echo "promoted ${rev:0:7} to prod after dev was Synced and Healthy on it for ${SOAK}s ($(( $(date +%s) - start ))s at the gate)"
