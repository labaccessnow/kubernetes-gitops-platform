# Kubernetes GitOps Platform

A multi-tenant Kubernetes platform I run in production. It hosts several of my own live web
applications, and every pattern documented here is in use — this is a sanitised snapshot of a
working system rather than a reference architecture.

The whole topology fits in one sentence:

!!! quote "The design in one line"
    **Spread the stateless across two failure domains, pin the stateful to one, encrypt the
    backups across the boundary — and put the tiebreaker somewhere neither domain can take down.**

## The constraint that shaped it

Two independent failure domains, each behind its own firewall, each able to go down for maintenance
without warning. That is the interesting part: a naive two-zone cluster loses etcd quorum the moment
one side disappears, so "highly available across two sites" is a contradiction unless something
breaks the tie from outside both.

Here that is a **control-plane node in a third domain** (cloud). Losing either firewall entirely
leaves quorum intact.

## What's here

<div class="grid cards" markdown>

-   :material-sitemap: **[Architecture](architecture.md)**

    Why two domains need a third, how workloads are placed, and the difference between spreading
    and pinning.

-   :material-source-branch: **[GitOps](gitops.md)**

    App-of-apps, why `prune` is deliberately off, and how secrets stay in git safely.

-   :material-cube-outline: **[The app chart](app-chart.md)**

    One Helm chart renders an entire tenant. Onboarding is a values file, not new manifests.

-   :material-server-network: **[Shared services](shared-services.md)**

    MongoDB replica set, Traefik ingress with platform-wide security headers, KEDA scale-to-zero.

-   :material-wrench: **[Operations](operations.md)**

    Onboarding an app, backups and restore, and what actually happens when a zone dies.

</div>

## Stack

`Kubernetes (k3s)` · `ArgoCD` · `Helm` · `SealedSecrets` · `Traefik` · `cert-manager` · `KEDA` ·
`MongoDB` · `PostgreSQL` · `Redis` · `restic` · `age` · `Prometheus`

It runs on k3s, but nothing here depends on k3s. The charts, Applications and ingress definitions
are ordinary Kubernetes, kept deliberately portable — moving to EKS or AKS is a values change and a
DNS cutover, not a rewrite.

## Reading this as a hiring manager

The parts worth your time are the **decisions**, not the YAML:

- why `prune: false` is the right call even though it is the "wrong" GitOps answer —
  [GitOps](gitops.md#why-prune-is-off)
- why stateful workloads are pinned while stateless ones are spread —
  [Architecture](architecture.md#spread-the-stateless-pin-the-stateful)
- why backups are pinned to the *other* zone from the database —
  [Operations](operations.md#backups)
- why the read-API sibling gets its own credentials rather than the app's —
  [The app chart](app-chart.md#the-read-api-sibling)

!!! note "About this snapshot"
    Internal addressing, DDNS endpoints and sealed secret payloads are removed or replaced with
    documentation values. RFC1918 ranges that remain are NetworkPolicy CIDR selectors, not host
    addresses. The live repository stays private, because ArgoCD reconciles from it.
