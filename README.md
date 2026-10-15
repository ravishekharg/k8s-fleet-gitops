# k8s-fleet-gitops

Fleet management for several Kubernetes clusters from one Argo CD hub: clusters join by label,
get the same platform layer and governance, and receive releases dev first, then prod through a
promotion gate, one prod cluster at a time.

```
                 fleet git repo (fleet/)
                         │
                Argo CD on the hub cluster
       ApplicationSets with cluster generators on labels
        ┌────────────────┼──────────────────┐
   dev (env=dev)   prod-eu (env=prod)   prod-us (env=prod)
   policies: Audit  policies: Enforce    policies: Enforce
   app from main    app from the prod branch: moved by scripts/promote.sh only
                    after dev is Healthy on the commit; one cluster at a time
```

| Layer | What every managed cluster gets | Where |
|---|---|---|
| Policy engine | Kyverno | [`fleet/argocd/platform.yaml`](fleet/argocd/platform.yaml) |
| Governance | No privileged pods, pinned image tags, requests and memory limits, no hostPath; **Audit on dev, Enforce on prod** | [`fleet/charts/fleet-policies`](fleet/charts/fleet-policies) |
| Baseline | Team namespaces with Pod Security labels, quotas, default-deny ingress; cluster identity | [`fleet/charts/baseline`](fleet/charts/baseline) |
| App | podinfo: dev follows `main`, prod follows `prod`; the promotion gate moves `prod` only after dev is Healthy on the commit; RollingSync updates prod one cluster at a time | [`fleet/argocd/apps.yaml`](fleet/argocd/apps.yaml), [`scripts/promote.sh`](scripts/promote.sh) |

Onboarding a cluster = registering it in the hub with labels `fleet/managed=true`, `env`,
`region`. Nothing in git names a cluster. Team apps live in an Argo CD project that can't create
quotas or network policies, so a team can't remove its own guardrails.

It's a personal project built for interviews, not code from a former employer.

## Status
| Check | Status |
|---|---|
| Charts render for dev and prod; prod renders Enforce, dev Audit | Passing (`scripts/static-checks.sh`) |
| All manifests, including Argo CD ApplicationSets/AppProjects and Kyverno policies, validate against their schemas | 23 / 23 valid |
| Policy unit tests (Kyverno CLI: good pod passes, each bad pod fails the right rule, system namespaces exempt) | 16 / 16 passing |
| Live fleet test (`scripts/fleet-test.sh`): bootstrap, governance, drift self-heal, onboarding by label, promotion and one-at-a-time prod rollout, gate refusing a bad release | **13 / 13 passing** in CI's `fleet` job (four kind clusters; not run locally) |

## Run it
Needs Docker, kind, kubectl, helm (and about 4 GB of free memory: four single-node clusters).
```bash
bash scripts/static-checks.sh     # offline: render, schema-validate, policy unit tests
bash scripts/up.sh                # hub + dev + prod-eu + prod-us + a Git server, Argo CD, registration
bash scripts/fleet-test.sh        # the six live checks
bash scripts/promote.sh           # promote main's head to prod (refuses unless dev is healthy on it)
bash scripts/down.sh
```
Everything uses its own kubeconfig (`/tmp/kubeconfig-fleet`), never the machine's current
context. The Git server in the lab (`fleet-git`) stands in for GitHub/GitLab; on a real fleet
the `repoURL`s point at the real repository.

Design, trade-offs and what a production fleet adds: [`docs/design.md`](docs/design.md).
