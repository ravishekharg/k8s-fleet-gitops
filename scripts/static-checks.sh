#!/usr/bin/env bash
# Offline checks for the fleet repo (no clusters): render every chart for every env, validate
# against Kubernetes and CRD schemas, and unit-test the policies with the Kyverno CLI.
set -euo pipefail
cd "$(dirname "$0")/.."
KYVERNO_VERSION=v1.13.2
KUBECONFORM_VERSION=v0.6.7
bin=$(mktemp -d); trap 'rm -rf "$bin"' EXIT
curl -sSL "https://github.com/kyverno/kyverno/releases/download/$KYVERNO_VERSION/kyverno-cli_${KYVERNO_VERSION}_linux_x86_64.tar.gz" | tar xz -C "$bin" kyverno
curl -sSL "https://github.com/yannh/kubeconform/releases/download/$KUBECONFORM_VERSION/kubeconform-linux-amd64.tar.gz" | tar xz -C "$bin" kubeconform
schemas=(-schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')

echo "== render and validate"
out=$(mktemp -d)
for env in dev prod; do
  values=(); [ -f "fleet/charts/fleet-policies/values-$env.yaml" ] && values=(-f "fleet/charts/fleet-policies/values-$env.yaml")
  helm template fleet/charts/fleet-policies "${values[@]}" > "$out/policies-$env.yaml"
  helm template fleet/charts/baseline --set cluster=c --set env="$env" --set region=eu > "$out/baseline-$env.yaml"
done
grep -q "failureAction: Enforce" "$out/policies-prod.yaml" && ! grep -q "failureAction: Enforce" "$out/policies-dev.yaml" \
  && echo "prod renders Enforce, dev renders Audit"
"$bin/kubeconform" -strict -summary "${schemas[@]}" "$out"/*.yaml fleet/argocd/*.yaml fleet/bootstrap/*.yaml

echo "== policy unit tests (kyverno CLI)"
cp "$out/policies-prod.yaml" tests/policies/policies.yaml
"$bin/kyverno" test tests/policies --remove-color
rm -f tests/policies/policies.yaml
