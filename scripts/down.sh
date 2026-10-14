#!/usr/bin/env bash
# Remove the lab: the four kind clusters and the Git server.
export KUBECONFIG=${KUBECONFIG:-/tmp/kubeconfig-fleet}
for c in hub dev prod-eu prod-us; do kind delete cluster --name "fleet-$c" >/dev/null 2>&1 || true; done
docker rm -f fleet-git >/dev/null 2>&1 || true
rm -f "$KUBECONFIG" /tmp/fleet-bootstrapped-at
echo "fleet removed"
