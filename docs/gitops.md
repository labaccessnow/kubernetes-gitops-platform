# GitOps

ArgoCD reconciles the cluster from this repository. Nothing is applied by hand, and ArgoCD's own
configuration is one of the applications it manages.

## App-of-apps

A single root `Application` watches `argocd/apps/` and turns every manifest it finds there into a
managed application:

```yaml
spec:
  source:
    repoURL: git@github.com:example-org/platform.git
    targetRevision: main
    path: argocd/apps
    directory:
      recurse: true
```

The consequence is the point: **onboarding application number two is a file, not a project.** Drop
an `Application` manifest into `argocd/apps/`, commit, and it exists. There is no separate pipeline
to register it with, and no bootstrap step that someone has to remember six months later.

What currently lives there:

| Application | Purpose |
|---|---|
| `argocd-selfmanage` | ArgoCD reconciling its own configuration |
| `sealed-secrets-app` | the SealedSecrets controller |
| `sealed-payloads-app` | the encrypted payloads themselves |
| `keda` / `keda-http` | event- and request-driven autoscaling |
| `mongo-shared` | the shared MongoDB replica set |
| `tenant-ingress` | Traefik config, TLS store, security headers |
| `example-app` | a tenant, rendered from the shared chart |

## The sync policy is the interesting part

```yaml
syncPolicy:
  automated:
    selfHeal: true
    prune: false
```

Two settings, two deliberate and opposite choices.

### selfHeal: true

Drift is reverted automatically. A `kubectl edit` against a live resource does not survive — ArgoCD
puts it back. Git is the source of truth as an *enforced property* rather than a team agreement.

This is the easy one to accept in principle and the uncomfortable one in practice, because it means
the emergency hand-edit you make at 3am gets reverted while you are still looking at it. That is
working as intended: the fix belongs in git, and a change that cannot survive reconciliation was
never really applied.

### Why prune is off

`prune: true` is the textbook GitOps answer — the cluster should converge exactly on what git says,
including deletions. It is off here on purpose.

**Deleting a file is too easy, and too many things look like deleting a file.** A bad merge. A
rebase that drops a commit. A path filter that stops matching after a directory rename. With
pruning on, any of those silently deletes running production workloads, and the deletion is
"correct" — the cluster faithfully converged on a repository state nobody intended.

With pruning off, those mistakes are inert. The workload keeps running, someone notices the
manifest is missing, and the fix is a revert rather than a restore.

Removing an application is therefore a deliberate act:

```bash
kubectl delete application <name> -n argocd
```

!!! note "The trade being made"
    Pruning off means the cluster can hold resources git no longer describes — genuine drift, in
    the direction of *too much* rather than too little. That is the cost, and it is accepted
    knowingly: an orphaned resource is a cleanup task, while an over-eager prune is an incident.

## Secrets

Secrets are [Bitnami SealedSecrets](https://github.com/bitnami-labs/sealed-secrets): encrypted with
the cluster's public key, safe to commit, and decryptable only by the controller running inside the
cluster. Cleartext never enters the repository.

This is what makes app-of-apps honest. A GitOps setup where secrets are applied out-of-band has a
second, undocumented deployment path — and that path is invariably the one that is wrong after a
rebuild. Sealing them puts the whole system in one place.

The chart itself never creates secrets. It only *references* them:

```yaml
# values.yaml — key NAMES only, never values
app:
  secretEnv: [DATABASE_URL, SESSION_KEY]
existingSecret: ""   # "" defaults to <release>-secrets
```

The sealed payloads are omitted from this public snapshot; in the live repository they are
reconciled by the `sealed-payloads-app` Application like everything else.

## Build and deploy are separate

A strict split, worth stating because it is frequently blurred:

> **Application repositories build images and push to GHCR. This repository only deploys them.**

No build logic lives here — no Dockerfiles, no CI that compiles anything. This repository's job is
to describe desired state. That keeps the reconciliation loop fast, keeps image provenance in the
application's own history, and means a deployment rollback is a tag change rather than a rebuild.
