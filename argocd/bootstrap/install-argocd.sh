#!/usr/bin/env bash
# Bootstrap ArgoCD on the platform k3s cluster (one-time, idempotent).
# Reproduces the GitOps control plane from scratch. After this runs, ArgoCD
# manages everything else (including itself, via the platform-root app-of-apps).
#
#   KUBECONFIG=~/.kube/k3s-v515.yaml ./install-argocd.sh
#
# The repo deploy-key Secret is applied separately from SOPS (NOT in git):
#   sops -d <secrets> | jq -r .argocd_deploy_key.private_key  ->  Secret/repo-platform
# See README.md.
set -euo pipefail
ARGOCD_VERSION="v3.4.5"
NS="argocd"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Server-side apply: the applicationsets CRD is too large for client-side (last-applied) apply.
kubectl apply -n "$NS" --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Annotation-based resource tracking so ArgoCD never fights a chart's
# app.kubernetes.io/instance label (clean Helm-release adoption).
# timeout.reconciliation: 30s — fast GitOps sync without exposing a webhook
# endpoint (a push deploys within ~30s; default is 180s).
# timeout.reconciliation.jitter: 5s — the default jitter is 60s, which spreads the
# 30s resync to 30-90s (slow, non-deterministic new-commit pickup). 5s is plenty of
# spread for a handful of apps and keeps pickup at ~30-35s.
kubectl -n "$NS" patch configmap argocd-cm --type merge \
  -p '{"data":{"application.resourceTrackingMethod":"annotation","timeout.reconciliation":"30s","timeout.reconciliation.jitter":"5s"}}'
# argocd-cm changes need an application-controller restart to take effect.
kubectl -n "$NS" rollout restart statefulset/argocd-application-controller

kubectl -n "$NS" rollout status deploy/argocd-repo-server --timeout=180s
kubectl -n "$NS" rollout status deploy/argocd-server --timeout=180s
kubectl -n "$NS" rollout status statefulset/argocd-application-controller --timeout=180s

echo
echo "ArgoCD ${ARGOCD_VERSION} ready. Next:"
echo "  1. Apply the repo deploy-key Secret from SOPS (Secret/repo-platform)."
echo "  2. kubectl apply -f ../root-app.yaml   # app-of-apps; reconciles argocd/apps/*"
echo "  3. UI: kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "     admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
