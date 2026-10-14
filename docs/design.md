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

## Releases: promotion between environments, waves within prod
Two mechanisms, each doing the job it can do reliably:

1. **Dev → prod is a git promotion.** Dev clusters' app source follows `main`; prod clusters'
   follows a `prod` branch (one Go-template line in the ApplicationSet picks the branch from the
   cluster's `env` label). Merging a release to `main` reaches dev only. `scripts/promote.sh`
   fast-forwards `prod` to that commit, and only after every dev Application is Synced to
   exactly that commit and Healthy, continuously for a soak period (30 s here). A release whose
   pods can't start never passes the gate; reverting the commit on `main` recovers dev.
2. **Inside prod, ApplicationSet progressive sync** (`RollingSync`, step `env=prod`,
   `maxUpdate: 1`) updates one prod cluster at a time and waits for it to be Healthy before the
   next.

**Why not RollingSync for dev → prod as well?** It was the first design, and CI showed it
doesn't hold. RollingSync decides "step 1 is done" from each Application's last seen state. When
a commit lands, Argo CD refreshes apps in no particular order; if a prod app is seen OutOfSync
while dev still shows the old revision as Synced/Healthy, the controller thinks step 1 is complete
and syncs prod first. One run recorded prod-us synced 22 s *before* dev. It's a known upstream
issue (argoproj/argo-cd#22852), closed as not easily fixable. Ordering within a single step is
unaffected, so RollingSync stays for what it does well. Progressive sync is still behind a
feature flag (`applicationsetcontroller.enable.progressive.syncs`); with it on, the ApplicationSet
controller, not the Application's automated policy, triggers the syncs.

**A sync takes the branch head, not the commit a rollout started with.** That's why prod follows
a branch only the gate moves: nothing merged to `main` can slip into prod in the middle of a prod
rollout.

What "Healthy" can't catch: a release that starts fine but is wrong (errors, latency). The gate
is the place for that: query the SLOs (error rate, p99 latency) over the soak window before
moving `prod`, or run Argo Rollouts with an AnalysisTemplate inside each cluster. In a real
setup the gate runs as a pipeline job (or Kargo) instead of a script.

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
