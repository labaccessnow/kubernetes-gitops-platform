# Kubernetes GitOps Platform

A multi-tenant Kubernetes platform I run in production: **GitOps-reconciled, split across two
independent failure domains, with a third-domain control-plane tiebreaker** so either domain can
fail without freezing the cluster.

This is a sanitised snapshot of the live platform that hosts several of my own production web
applications. It is a working system, not a reference example — every pattern here is in use.

---

## Why it's built this way

**The constraint:** two independent failure domains, each behind its own firewall, each capable of
going down for maintenance without warning. A naive 2-zone etcd loses quorum the moment one side
goes away.

**The design:** 4 worker/server nodes split evenly across the two domains, plus a **control-plane
tiebreaker in a third domain** (cloud). Quorum survives losing either firewall entirely.

- **Stateless workloads** spread across zones via a `platform.zone` label — the scheduler keeps
  replicas on both sides.
- **Stateful workloads** are pinned per zone (`placement.dbZone`), because a database that
  wanders between failure domains is worse than one that stays put.
- **Cross-zone backups are age-encrypted**, so the recovery path doesn't depend on the zone that
  just failed.

That trade — spread the stateless, pin the stateful, encrypt across the boundary — is the whole
topology in one sentence.

---

## GitOps

ArgoCD runs an **app-of-apps**: a root `Application` watches `argocd/apps/`, and every manifest
dropped there becomes a managed app. Onboarding app number two is a file, not a project.

Two deliberate choices worth calling out, both in [`argocd/root-app.yaml`](argocd/root-app.yaml):

```yaml
syncPolicy:
  automated:
    selfHeal: true    # drift gets reverted automatically
    prune: false      # deleting a file NEVER deletes running workloads
```

`selfHeal: true` means manual `kubectl edit` on a live resource is reverted — git is the source of
truth, enforced rather than requested.

`prune: false` is the more interesting one. Pruning is the "correct" GitOps answer, and I turned it
off on purpose: a bad merge, a rebase mistake, or a mis-scoped path change should not silently
delete production workloads. Removing an app is a deliberate act
(`kubectl delete application <name> -n argocd`), not a side effect of a git operation. **ArgoCD
also self-manages** — its own configuration is one of the applications it reconciles.

**Secrets** are [Bitnami SealedSecrets](https://github.com/bitnami-labs/sealed-secrets): encrypted
with the cluster's public key, safe to commit, decryptable only in-cluster. Cleartext secrets never
touch the repository. (The sealed payloads themselves are omitted from this public snapshot.)

---

## The reusable app chart

Onboarding a tenant is a values file, not a bespoke set of manifests. One chart
([`charts/app/`](charts/app/)) renders the whole stack:

| Template | What it gives a tenant |
|---|---|
| `deployment.yaml` | app + optional worker, zone-spread scheduling |
| `postgres.yaml` / `redis.yaml` | per-tenant stateful backing services |
| `ingress.yaml` | **multi-domain** ingress — one app, many hostnames |
| `backup.yaml` | scheduled restic backup, encrypted, cross-zone |
| `cronjobs.yaml` | arbitrary per-tenant scheduled jobs |
| `rbac.yaml` | least-privilege service account per tenant |
| `readapi.yaml` | optional read-only API surface |

`scripts/onboard-app.sh` scaffolds a new tenant from the chart defaults.

The split of concerns is strict: **application repositories build images and push to GHCR; this
repository only deploys them.** No build logic lives here.

---

## Shared services

**MongoDB replica set** ([`mongo-shared/`](mongo-shared/)) — a StatefulSet shared across tenants,
with:
- a **NetworkPolicy** restricting access to the namespaces that should reach it
- a **backup CronJob** (restic, encrypted, off-cluster)
- a **Prometheus exporter** for replica-set health

**Ingress** ([`tenant-ingress/`](tenant-ingress/)) — Traefik with a wildcard certificate, a default
TLS store, and a **security-headers middleware** applied across tenants so hardening is a platform
property rather than a per-app checkbox.

**Autoscaling** — KEDA plus `keda-http` for event- and request-driven scaling, including
scale-to-zero for low-traffic tenants.

---

## Portability

The platform runs on **k3s** today. Nothing here depends on k3s: the charts, the ArgoCD
applications, and the ingress definitions are ordinary Kubernetes, deliberately kept portable to
EKS/AKS. The migration path is a values change and a DNS cutover, not a rewrite.

---

## Stack

`Kubernetes (k3s)` · `ArgoCD` · `Helm` · `SealedSecrets` · `Traefik` · `cert-manager` ·
`KEDA` · `MongoDB` · `PostgreSQL` · `Redis` · `restic` · `age` · `Prometheus`

---

## Notes on this snapshot

Sanitised for publication: internal addressing, DDNS endpoints and sealed secret payloads are
removed or replaced with documentation values. RFC1918 ranges that remain are NetworkPolicy CIDR
selectors, not host addresses. The live repository stays private because ArgoCD reconciles from it.

---

**James Son** — Senior Network, Security, Cloud & Automation Engineer
[james-resume.com](https://james-resume.com) · [github.com/labaccessnow](https://github.com/labaccessnow)
