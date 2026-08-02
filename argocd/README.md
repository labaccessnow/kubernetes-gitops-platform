# GitOps (ArgoCD) — the auto-deploy path

ArgoCD watches this repo and reconciles the cluster to match it. **Push to `main` → the
cluster converges.** Manual `helm`/`kubectl` drift is reverted (`selfHeal`). This is the
same control plane you'd run on EKS/AKS later — the manifests move over unchanged.

## Layout
```
argocd/
  bootstrap/install-argocd.sh   one-time cluster bootstrap (pins ArgoCD version)
  root-app.yaml                 app-of-apps; watches argocd/apps/ (recurse)
  apps/<app>.yaml               one Application per platform app  (example-app = #1)
```

## How it fits together
- **platform-root** (`root-app.yaml`) is the only thing applied by hand. It manages every
  `Application` in `argocd/apps/`. Add an app = add `argocd/apps/<app>.yaml` + push.
- Each app Application deploys `charts/app` with `apps/<app>/values.yaml` (multi-source
  `$values` ref), so it renders identically to the manual `helm upgrade --install`.

## Sync policy (chosen 2026-06-25)
- `timeout.reconciliation: 30s` + `timeout.reconciliation.jitter: 5s` (argocd-cm) — a push
  to `main` deploys within ~30-35s. We deliberately use a short poll instead of a GitHub
  webhook so nothing is exposed inbound (no public endpoint, no Cloudflare Tunnel). Defaults
  (180s + 60s jitter) make pickup slow and non-deterministic; the 5s jitter is the key fix.
- `automated.selfHeal: true` — true auto-deploy + drift correction.
- `automated.prune: false` — a removed manifest never auto-deletes a running workload or a
  StatefulSet PVC. Delete an app deliberately: `kubectl delete application <name> -n argocd`.
- No `resources-finalizer` — deleting an `Application` orphans (does not cascade-delete) its
  workloads, the safe failure mode for the stateful DB apps.

## Secrets are NOT in git
ArgoCD manages the chart only. App secrets, the GHCR pull secret, and cert-manager's
Cloudflare token are applied out-of-band from SOPS:
- repo deploy key → `Secret/repo-platform` (label `argocd.argoproj.io/secret-type: repository`),
  private key in SOPS `argocd_deploy_key` (read-only GitHub deploy key, this repo only).
- per-app: see `apps/<app>/SECRETS.md`.
(Sealed-secrets / external-secrets to bring these into GitOps safely is a planned follow-up.)

## Bootstrap from scratch
```sh
export KUBECONFIG=~/.kube/k3s-v515.yaml
./bootstrap/install-argocd.sh
# apply repo deploy-key Secret from SOPS (see bootstrap output), then:
kubectl apply -f root-app.yaml
```

## UI access (internal only — not publicly exposed)
```sh
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080  user: admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```
