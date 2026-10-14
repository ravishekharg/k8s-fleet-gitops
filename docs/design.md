# Design notes

## Hub and spoke
One Argo CD (the hub) manages every cluster (the spokes). A cluster joins the fleet by being
registered in the hub as a cluster Secret with labels:

| Label | Used for |
|---|---|
| `fleet/managed=true` | Gets the fleet at all. Registering without it lets you stage a cluster before it takes traffic |
| `env=dev\|prod` | Policy mode (Audit on dev, Enforce on prod), app values, and the rollout wave |
| `region=eu\|us` | Shown in the app; available to target region-specific add-ons |

Every ApplicationSet uses a **cluster generator** on those labels, so nothing in git names a
cluster: adding the tenth cluster is one labelled Secret, not ten files.

Alternatives: one Argo CD per cluster (simpler blast radius, but N control planes to upgrade
and no fleet view), or Argo CD's agent model / pull-based tools (Flux, OCM) when spokes can't be
reached from the hub (on-prem behind NAT). Here the hub reaches each spoke's API server; for
EKS that means an IAM role per cluster (Argo CD's `awsAuthConfig`) instead of client certs.

## Layers and ownership
| Layer | ApplicationSet | Owner | Project limits |
|---|---|---|---|
| Policy engine | `kyverno` | Platform | `platform` project: may create cluster-scoped resources |
| Governance | `fleet-policies` | Platform / security | same |
| Baseline | `baseline`: namespaces, quotas, default-deny networking, cluster identity | Platform | same |
| Apps | `podinfo` | Team | `apps` project: only its namespace, cannot create ResourceQuotas or NetworkPolicies (so a team can't lift its own guardrails) |

## Governance: Audit on dev, Enforce on prod
The same policies go everywhere; only `failureAction` differs (`values-prod.yaml`). Dev admits
violations and records them in PolicyReports, so a team sees what would be blocked before the
change reaches prod; prod rejects them at admission. System namespaces are excluded. The
policies are unit-tested offline with the Kyverno CLI (`tests/policies`) and enforced live in
`fleet-test.sh`.

## Rollout waves (ApplicationSet progressive sync)
`strategy: RollingSync` on the app ApplicationSet:
1. all `env=dev` clusters, then
2. `env=prod` clusters, `maxUpdate: 1`: one at a time.

A step starts only when every Application in the previous one is Healthy. A release whose pods
can't start (bad tag, crash on boot) stays Progressing/Degraded on dev and never reaches prod;
reverting the commit recovers dev. Progressive sync is still behind a feature flag in Argo CD
(`applicationsetcontroller.enable.progressive.syncs`), and with it on, the ApplicationSet
controller (not the Application's own automated policy) triggers the app syncs.

A sync always takes the newest commit on `main`; a wave doesn't pin the revision it started with.
If a second release is merged while the first wave is still in its prod step, the clusters not yet
updated skip straight to the second release without it ever passing dev (the first CI run here
did exactly that). So release one at a time: merge the next only after the ApplicationSet status
shows every app Healthy at the current commit, which is what `fleet-test.sh` waits for.

What "Healthy" can't catch: a release that starts fine but is wrong (errors, latency). That
needs analysis on metrics between waves: Argo Rollouts with an AnalysisTemplate inside each
cluster, or a soak time plus an SLO check before the next wave.

## Drift
Platform Applications have `selfHeal: true`: Argo CD watches the live objects, and a manual
change (here: deleting the default-deny NetworkPolicy on a prod cluster) is reverted within
seconds. Changes go through git or not at all; break-glass is pausing auto-sync on that one
Application, which is visible and audited.

## What a production fleet adds
- Argo CD itself HA (controller sharding by cluster), SSO with RBAC per project, and the hub
  managed by GitOps too.
- Cluster registration automated from the cluster's creation (Terraform output or Crossplane
  writes the labelled Secret), so onboarding is part of provisioning.
- Secrets from a vault (External Secrets Operator) per cluster, never in git.
- Per-wave soak times and metric analysis; maintenance windows (`syncWindows`) for prod.
- Policy reports aggregated across clusters (Policy Reporter UI, or Prometheus metrics from
  Kyverno) for a fleet compliance view.
