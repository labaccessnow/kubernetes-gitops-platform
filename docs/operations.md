# Operations

## Onboarding an application

Three steps, in this order.

**1. Scaffold the values file**

```bash
scripts/onboard-app.sh myapp
```

Copies the chart defaults to `apps/myapp/values.yaml` and writes `apps/myapp/SECRETS.md` listing
the exact keys that tenant's Secret must contain. It refuses to overwrite an existing directory, so
running it twice is safe.

**2. Create the secret**

Every key listed under `app.secretEnv` — plus `POSTGRES_USER` / `POSTGRES_PASSWORD` /
`POSTGRES_DB` if `postgres.enabled` — must exist in `Secret/myapp-secrets` in namespace `myapp`.
Seal it; never commit cleartext. See [GitOps → Secrets](gitops.md#secrets).

**3. Hand it to ArgoCD**

Drop an `Application` manifest into `argocd/apps/` and commit. The root app picks it up and
reconciles. No registration step, no pipeline to update.

For a dry run, or on a cluster without ArgoCD yet, the same thing by hand:

```bash
helm upgrade --install myapp charts/app -n myapp --create-namespace -f apps/myapp/values.yaml
```

!!! tip "Order matters"
    Create the Secret before ArgoCD syncs the application. The chart *references* the Secret and
    never creates it, so an application that syncs first will crash-loop on missing environment
    until the Secret appears — recoverable, but noisy and easy to misdiagnose as an image problem.

## Backups

Enabled per tenant, and only meaningful alongside `postgres.enabled`:

```yaml
backup:
  enabled: true
  schedule: "0 3 * * *"
  zone: "fw2"              # a DIFFERENT platform.zone than the database
  repoStorage: 5Gi
  retention: { daily: 7, weekly: 4 }
  passwordSecret: ""       # "" → <release>-backup
```

### What the job actually does

A CronJob with two stages:

1. **initContainer `pg-dump`** — `pg_dump -Fc` against the tenant's Postgres into a shared `work`
   volume, using credentials from the tenant's own Secret. Custom format (`-Fc`) so restores can be
   selective and parallel.
2. **container `restic`** — `restic backup` of that dump into the repository, then `forget` to apply
   retention, then `check` to verify integrity.

restic is doing three jobs that are easy to conflate: **encryption** (the repository is encrypted at
rest with `RESTIC_PASSWORD`), **retention** (`forget` prunes to the daily/weekly policy), and
**verification** (`check` catches a repository that has quietly corrupted). A backup system without
the third is a hope, not a guarantee.

### Why the zone matters

```yaml
zone: "fw2"   # while the database is pinned to fw1
```

The repository PVC uses `local-path` with `WaitForFirstConsumer`, so it binds to whichever node the
CronJob lands on. Pinning that to the *other* failure domain from the database is the entire point:
a backup on the same node as the database is a second copy of the thing about to be lost.

### Moving off-cluster

The repository backend is a PVC today. restic speaks S3, B2 and MinIO natively, so pointing it
off-site is a `RESTIC_REPOSITORY` change and a credential — **no template change**. That was a
deliberate choice at design time rather than a happy accident.

## Restoring

The restore path is the one nobody tests, so it is worth writing down:

```bash
# 1. list what you have
restic -r /repo snapshots

# 2. restore a dump out of the repository
restic -r /repo restore <snapshot-id> --target /work

# 3. load it back
pg_restore -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean /work/<dump>
```

Run it from a pod with the repository PVC mounted and `RESTIC_PASSWORD` available. Because the
repository lives in the other zone, this works while the database's own zone is still down — which
is the scenario it exists for.

!!! warning "Test the restore, not the backup"
    A green CronJob proves a dump was written. It does not prove the dump loads. `restic check`
    covers repository integrity but not whether `pg_restore` will accept the contents. Restore into
    a scratch database occasionally and confirm the row counts.

## When a zone goes down

What actually happens, in order:

1. **Quorum holds.** The third-domain control-plane member means etcd keeps a majority. The API
   server stays writable and the scheduler keeps working — see
   [Architecture](architecture.md#two-domains-need-a-third).
2. **Stateless workloads survive** if they were spread. With `zoneSpreadRequired: false` this is
   *likely* rather than guaranteed, since the scheduler may have collapsed replicas onto one side
   during an earlier rolling restart. Apps that must survive this need the hard constraint.
3. **Stateful workloads in that zone are down**, and correctly so. Their PVCs are local to nodes
   that are gone. They come back when the zone does.
4. **Backups are unaffected**, because they were pinned elsewhere.

The honest summary: this topology guarantees the *cluster* survives losing a domain, and that
stateless workloads can. It does not make a node-local database highly available — that would need
replicated storage or a database that replicates itself, both of which are a different set of
trade-offs.

## Day-to-day

| Task | How |
|---|---|
| See what ArgoCD manages | `kubectl get applications -n argocd` |
| Force a sync | `argocd app sync <name>` — or just commit; auto-sync is on |
| Remove an application | `kubectl delete application <name> -n argocd` (deliberate — [prune is off](gitops.md#why-prune-is-off)) |
| Check replica-set health | the Prometheus exporter in [`mongo-shared/`](shared-services.md#mongodb-replica-set) |
| Undo a hand-edit | nothing to do — `selfHeal` reverts it |

That last row is worth internalising. Editing a live resource is not a way to change anything
durably; the edit is reverted, usually before you have finished reading the output. Changes go in
git.
