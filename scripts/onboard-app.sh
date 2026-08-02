#!/usr/bin/env bash
# Scaffold a new app from the chart defaults: apps/<app>/{values.yaml,SECRETS.md}.
set -euo pipefail
app="${1:?usage: onboard-app.sh <app>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/apps/$app"
[ -e "$dir" ] && { echo "apps/$app already exists" >&2; exit 1; }
mkdir -p "$dir"
cp "$root/charts/app/values.yaml" "$dir/values.yaml"
cat > "$dir/SECRETS.md" <<EOF
# $app secrets

Create \`Secret/$app-secrets\` in namespace \`$app\` with the keys listed under
\`app.secretEnv\` in values.yaml (+ POSTGRES_USER/PASSWORD/DB if postgres.enabled).
Never commit values — render from SOPS.
EOF
echo "scaffolded apps/$app/{values.yaml,SECRETS.md}"
echo "next: edit values.yaml, create the secret, then:"
echo "  helm upgrade --install $app charts/app -n $app --create-namespace -f apps/$app/values.yaml"
