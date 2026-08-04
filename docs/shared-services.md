# Shared services

Three things every tenant relies on but none of them owns: a shared database, the ingress edge, and
autoscaling. Each is an ArgoCD `Application` like any tenant, so the platform's own infrastructure
is reconciled by the same loop as the workloads running on it.

## MongoDB replica set

`mongo-shared/` runs a MongoDB StatefulSet shared across tenants — one replica set rather than a
database per tenant, with isolation enforced at the database and network layer instead of by
duplicating infrastructure.

The Service is **headless**, which gives each pod a stable DNS name of the form
`mongo-shared-<n>.mongo-shared.mongo-shared.svc`. That is a requirement rather than a preference:
replica set members address each other by name, and a normal load-balanced Service would hand a
client a random member when it asked for a specific one.

Authentication uses a **keyfile** for intra-cluster member auth, with root credentials supplied from
`mongo-shared-secret`. An init container fixes the keyfile's ownership and permissions before MongoDB
starts — MongoDB refuses to start on a keyfile that is group- or world-readable, and a ConfigMap or
Secret mount does not arrive with the permissions it wants.

Three things wrap it:

- **`30-networkpolicy.yaml`** — restricts access to the namespaces that legitimately need the
  database. A shared datastore without a NetworkPolicy is only isolated by convention, and
  convention does not survive a compromised tenant.
- **`40-backup-cronjob.yaml`** — scheduled restic backup, encrypted and off-cluster.
- **`50-exporter.yaml`** — a Prometheus exporter for replica-set health, so a member that has fallen
  out of the set is visible before it matters.

## Ingress

`tenant-ingress/` configures Traefik as the platform edge.

### Security headers as a platform property

The piece worth highlighting is `security-headers-middleware.yaml` — a Traefik `Middleware` applied
across tenants:

```yaml
contentTypeNosniff: true
referrerPolicy: strict-origin-when-cross-origin
stsSeconds: 63072000          # two years, for HSTS preload
```

Plus CSP and the rest of the standard set.

Applying this at the edge makes hardening **a property of the platform rather than a checklist item
per application**. A new tenant is secure by default, and cannot regress by forgetting something —
which is the failure mode of every "remember to add these headers" convention ever written down.

### TLS

- `wildcard-certificate.yaml` — a cert-manager `Certificate` requesting a wildcard from the
  `letsencrypt` ClusterIssuer
- `traefik-default-tlsstore.yaml` — a Traefik `TLSStore` named `default`, which is what makes that
  wildcard the fallback certificate for any host without a more specific one

The pairing matters. A wildcard certificate on its own does nothing for a request that arrives
without SNI, or for a hostname Traefik has no explicit route for — the default TLSStore is what
turns "we have a wildcard" into "every host is served over TLS."

Tenants can still request per-host certificates through the chart
([`ingress.tls.clusterIssuer`](app-chart.md#multi-domain-ingress)); the wildcard is the floor, not
the ceiling.

### Traefik configuration

`traefik-config.yaml` is a k3s `HelmChartConfig`, which is how k3s allows customising its bundled
Traefik without forking the chart or disabling the packaged component. This is the one genuinely
k3s-shaped file in the repository; on EKS or AKS the equivalent is the ingress controller's own
Helm values.

## Autoscaling

**KEDA** plus **`keda-http`** provide event- and request-driven scaling, including **scale-to-zero**
for low-traffic tenants.

Scale-to-zero is what makes multi-tenancy affordable at this size. A tenant that receives no traffic
for hours costs nothing but storage, and `keda-http` holds the first request while the pod starts
rather than returning an error — so the tenant looks slow for one request rather than down.

The trade is real and worth stating: the first request after an idle period pays the cold-start
cost. For a low-traffic tenant that is the right bargain. For a latency-sensitive one it is not, and
those simply keep a floor of one replica.
