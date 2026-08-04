# The app chart

One Helm chart (`charts/app/`) renders an entire tenant. Onboarding is a values file, not a bespoke
set of manifests — which is the difference between a platform and a collection of deployments that
happen to share a cluster.

## What one values file renders

| Template | What the tenant gets |
|---|---|
| `deployment.yaml` | the app, plus an optional worker, with zone-spread scheduling |
| `postgres.yaml` / `redis.yaml` | per-tenant stateful backing services, node-pinned |
| `ingress.yaml` | multi-domain ingress — one app, many hostnames |
| `backup.yaml` | scheduled `pg_dump` → restic, encrypted, cross-zone |
| `cronjobs.yaml` | arbitrary per-tenant scheduled jobs on the app image |
| `rbac.yaml` | a least-privilege ServiceAccount |
| `readapi.yaml` | an optional read-only API surface |
| `service.yaml` | ClusterIP wiring |

Everything is off by default. A minimal tenant is a stateless deployment and an ingress; each
additional capability is one boolean.

## The contract

`charts/app/values.yaml` is written as a contract rather than a config dump — every field carries
the reasoning next to it. The core of it:

```yaml
image:
  repository: ghcr.io/example-org/CHANGEME
  tag: latest

app:
  replicas: 2
  port: 8000
  env: {}          # NON-secret values, inline
  secretEnv: []    # key NAMES only — pulled from <release>-secrets
  probes:
    enabled: true
    livenessPath: /healthz
    readinessPath: /readyz

worker:
  enabled: false   # same image, different command
```

!!! warning "Secret values never appear here"
    `secretEnv` lists the **names** of keys the app expects to find in the Kubernetes Secret
    `<release>-secrets`. The chart references that Secret and never creates it. Values come from
    SealedSecrets — see [GitOps → Secrets](gitops.md#secrets).

## The read-API sibling

`readApi` deserves its own note, because it is the clearest example of the chart taking a security
position rather than just exposing a toggle.

```yaml
readApi:
  enabled: false
  replicas: 2
  command: ["uvicorn", "app.readapi:app", "--host", "0.0.0.0", "--port", "8000"]
  env: {}          # its OWN env
  secretEnv: []    # its OWN secrets
```

It runs the **same image** as the app but as a deliberately weaker sibling:

- it runs under the **default ServiceAccount**, never the tenant-manager RBAC
- it gets **its own** `env` and `secretEnv` rather than inheriting the app's

That second point is the one that matters. The obvious design is to have the read API inherit the
app's environment — it is the same image, after all. But the read path only needs a control-database
handle, a decryption key and a **read-only** database URI. Handing it the app's full credentials
would give an internet-facing read surface the ability to write, for no benefit beyond a shorter
values file.

The worker, by contrast, *does* inherit `app.env` and `app.secretEnv` — it is the same trust level
doing the same work on a different schedule.

## Placement

```yaml
placement:
  zoneSpread: true
  zoneSpreadRequired: false
  zoneLabel: platform.zone
  dbZone: ""
  dataLabel: platform.data
```

Covered in depth in [Architecture](architecture.md#spread-the-stateless-pin-the-stateful). The short
version: stateless replicas spread across failure domains, stateful services pin to one.

## Multi-domain ingress

```yaml
ingress:
  enabled: true
  className: ""                  # "" = cluster default (Traefik on k3s)
  domains: []                    # ANY number of FQDNs, across ANY apexes
  tls:
    enabled: true
    clusterIssuer: letsencrypt   # per-host certs by default
    # wildcardSecret: ""         # or reuse a pre-issued *.<apex> DNS-01 cert
```

`domains` is a flat list with no apex restriction, so one application can serve
`example.com`, `www.example.com` and `something-else.org` from a single release. That is a real
requirement for anything hosting multiple brands, and it is the kind of thing that becomes painful
if the chart assumed one apex per app.

TLS defaults to per-host certificates from cert-manager. `wildcardSecret` exists for the case where
a DNS-01 wildcard is already issued — worth using when a tenant has many subdomains, since
per-host issuance would otherwise consume rate limits for no gain.

## Optional datastores

```yaml
postgres:
  enabled: false
  image: postgres:16
  storage: 5Gi
  storageClassName: ""   # "" = cluster default (local-path on k3s)

redis:
  enabled: false
  image: redis:7
  storage: 1Gi
```

Per-tenant and node-pinned. Postgres credentials are read from the same `<release>-secrets` Secret
(`POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB`), so there is one secret per tenant rather
than one per component.

## Scheduled jobs

```yaml
cronjobs: []
# each: {name, schedule, command, args, [env], [backoffLimit], [ttlSecondsAfterFinished]}
```

Each entry runs on the app image with the full app environment plus `RUN_MIGRATIONS=0` — because a
scheduled job that races the app into a migration is a genuinely unpleasant way to find out your
entrypoint does more than you thought.

## Scaffolding a new tenant

```bash
scripts/onboard-app.sh <app>
```

Copies the chart defaults to `apps/<app>/values.yaml` and writes an `apps/<app>/SECRETS.md` listing
exactly which keys that tenant's Secret must contain. It refuses to overwrite an existing directory.

Then:

```bash
helm upgrade --install <app> charts/app -n <app> --create-namespace -f apps/<app>/values.yaml
```

In practice the Helm command is what ArgoCD runs for you once the `Application` manifest lands in
`argocd/apps/` — the direct invocation is for a dry run or a cluster without ArgoCD yet. See
[Operations](operations.md#onboarding-an-application).
