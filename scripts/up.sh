#!/usr/bin/env bash
# A local fleet: a hub cluster running Argo CD, three spoke clusters, and a Git server, all in
# kind on one machine. Spokes are registered with labels; prod-us is registered but NOT yet
# labelled fleet/managed=true (the test onboards it by adding the label).
#
#   bash scripts/up.sh      (KUBECONFIG defaults to /tmp/kubeconfig-fleet: never touches the
#                            machine's current context)
#   bash scripts/down.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=${KUBECONFIG:-/tmp/kubeconfig-fleet}
NODE_IMAGE=${NODE_IMAGE:-kindest/node:v1.34.0}
ARGOCD_CHART=10.10.0                 # Argo CD v3.5.4
GIT_IMAGE=gitea/gitea:1.22.6
GIT_PORT=${GIT_PORT:-3300}
GIT_AUTH="fleet:fleet-lab-only"      # local lab credential; the repo itself is public in this Gitea
# name:env:region:managed
SPOKES=${SPOKES:-"dev:dev:eu:true prod-eu:prod:eu:true prod-us:prod:us:false"}
hub() { kubectl --context kind-fleet-hub "$@"; }
log() { printf '\n== %s\n' "$*"; }

log "clusters"
for c in hub $(for s in $SPOKES; do echo "${s%%:*}"; done); do
  kind get clusters 2>/dev/null | grep -qx "fleet-$c" || kind create cluster --name "fleet-$c" --image "$NODE_IMAGE" --wait 180s >/dev/null
  echo "   fleet-$c ready"
done

log "git server (fleet-git on the kind network)"
if ! docker inspect fleet-git >/dev/null 2>&1; then
  docker run -d --name fleet-git --network kind -p "127.0.0.1:$GIT_PORT:3000" \
    -e GITEA__security__INSTALL_LOCK=true -e GITEA__service__DISABLE_REGISTRATION=true \
    -e GITEA__server__ROOT_URL=http://fleet-git:3000/ -e GITEA__database__DB_TYPE=sqlite3 "$GIT_IMAGE" >/dev/null
fi
for _ in $(seq 60); do curl -sf "http://localhost:$GIT_PORT/api/healthz" >/dev/null && break; sleep 2; done
docker exec -u git fleet-git gitea admin user create --username fleet --password "${GIT_AUTH#*:}" \
  --email fleet@example.com --admin --must-change-password=false >/dev/null 2>&1 || true
curl -s -u "$GIT_AUTH" -X POST -H 'Content-Type: application/json' "http://localhost:$GIT_PORT/api/v1/user/repos" \
  -d '{"name":"fleet","private":false,"default_branch":"main"}' -o /dev/null
bash scripts/push-fleet.sh "initial fleet definition"

log "Argo CD on the hub (progressive syncs on, 15 s reconciliation for the demo)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd --kube-context kind-fleet-hub -n argocd --create-namespace \
  --version "$ARGOCD_CHART" \
  --set 'configs.params.applicationsetcontroller\.enable\.progressive\.syncs=true' \
  --set 'configs.cm.timeout\.reconciliation=15s' \
  --set dex.enabled=false --set notifications.enabled=false \
  --wait --timeout 600s 2>&1 >/dev/null | { grep -v 'unrecognized format' || true; } >&2

log "register spokes"
for s in $SPOKES; do
  IFS=: read -r name env region managed <<<"$s"
  cfg=$(mktemp)
  kind get kubeconfig --internal --name "fleet-$name" > "$cfg"
  q() { KUBECONFIG="$cfg" kubectl config view --raw --minify --flatten -o jsonpath="$1"; }
  server=$(q '{.clusters[0].cluster.server}')
  config=$(printf '{"tlsClientConfig":{"caData":"%s","certData":"%s","keyData":"%s"}}' \
    "$(q '{.clusters[0].cluster.certificate-authority-data}')" "$(q '{.users[0].user.client-certificate-data}')" \
    "$(q '{.users[0].user.client-key-data}')")
  rm -f "$cfg"
  hub -n argocd create secret generic "cluster-$name" --from-literal=name="$name" --from-literal=server="$server" \
    --from-literal=config="$config" --dry-run=client -o yaml | hub apply -f - >/dev/null
  hub -n argocd label secret "cluster-$name" --overwrite argocd.argoproj.io/secret-type=cluster \
    env="$env" region="$region" fleet/managed="$managed" >/dev/null
  echo "   $name -> $server  env=$env region=$region managed=$managed"
done

log "root application (everything else comes from git)"
hub apply -f fleet/bootstrap/root.yaml >/dev/null
date +%s > /tmp/fleet-bootstrapped-at
echo "   done. Argo CD UI: kubectl --kubeconfig $KUBECONFIG --context kind-fleet-hub -n argocd port-forward svc/argocd-server 8090:443"
