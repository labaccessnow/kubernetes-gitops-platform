# mongo-shared — shared MongoDB replica set (example-app scale-out)

ONE 3-member replica set (`rs0`) holding a database per tenant (`ns_<slug>`), replacing the
per-tenant Mongo StatefulSet. Lets example-app grow to 1,000+ tenants on the home k3s. Tenant
databases + scoped users are created dynamically by the control-plane
(`proxmox-automation/saas/control-plane/app/clients/mongo_admin.py`), not by these manifests.

Manifests: `10-statefulset.yaml` (RS + headless svc), `30-networkpolicy.yaml` (only tenant +
control-plane namespaces reach 27017), `40-backup-cronjob.yaml` (daily `mongodump` → restic).
Deployed by `argocd/apps/mongo-shared.yaml` (`prune: false` — never auto-deletes the RS or PVCs).

**RS init is a one-time MANUAL step (see below), not an auto Job.** MongoDB's localhost exception
(the only way to `rs.initiate` + create the first user under `--auth`) applies only to connections
*from the mongod host itself*, so a separate init pod can't do it — it must run via
`kubectl exec mongo-shared-0`. The StatefulSet uses `command:` (bypassing the image entrypoint),
so `MONGO_INITDB_ROOT_*` is NOT auto-applied either; the user is created in the same manual step.

## Users (least privilege)

| user | roles | used by |
|---|---|---|
| `gcadmin` | root | **break-glass / humans only** — nothing automated |
| `tenant-provisioner` | `userAdminAnyDatabase` + `readWriteAnyDatabase` + `dbAdminAnyDatabase` | the control-plane (`MONGO_SHARED_ADMIN_URI`): create/drop tenant dbs+users, ingester writes. Cannot touch RS config / shutdown / keyfile. |
| `backup` | built-in `backup` | the backup CronJob (read-for-dump only, cannot write) |

Created one-time as gcadmin: `db.getSiblingDB('admin').createUser({user:'tenant-provisioner', ...roles above})`
(same for `backup`). Restores stay a human break-glass op as gcadmin.

## Secret: `mongo-shared-secret` (ns `mongo-shared`)

Keys: `MONGO_ROOT_USERNAME`, `MONGO_ROOT_PASSWORD`, `MONGO_BACKUP_USERNAME`,
`MONGO_BACKUP_PASSWORD`, `MONGO_KEYFILE` (RS internal-auth keyfile), `RESTIC_PASSWORD`.
Seal it (bitnami sealed-secrets, same flow as `sealedsecrets/example-app/`):

```sh
ROOT_PW=$(openssl rand -base64 30 | tr -d '/+=' | head -c 32)
RESTIC_PW=$(openssl rand -base64 24)
openssl rand -base64 756 > /tmp/mongo-keyfile     # RS keyFile (base64, mongod-accepted)

kubectl create secret generic mongo-shared-secret -n mongo-shared \
  --from-literal=MONGO_ROOT_USERNAME=gcadmin \
  --from-literal=MONGO_ROOT_PASSWORD="$ROOT_PW" \
  --from-file=MONGO_KEYFILE=/tmp/mongo-keyfile \
  --from-literal=RESTIC_PASSWORD="$RESTIC_PW" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml --controller-name sealed-secrets --controller-namespace kube-system \
  > sealedsecrets/mongo-shared/mongo-shared-secret.sealed.yaml
shred -u /tmp/mongo-keyfile
```

Commit only the sealed file. Store `ROOT_PW`/`RESTIC_PW` in SOPS (`mongo_shared`).

## Control-plane wiring: `MONGO_SHARED_ADMIN_URI` (example-app-secrets)

The control-plane needs the privileged admin connection. Add key `MONGO_SHARED_ADMIN_URI` to the
existing `example-app-secrets` SealedSecret (`sealedsecrets/example-app/`):

```
mongodb://gcadmin:<ROOT_PW>@mongo-shared-0.mongo-shared.mongo-shared.svc.cluster.local:27017,mongo-shared-1.mongo-shared.mongo-shared.svc.cluster.local:27017,mongo-shared-2.mongo-shared.mongo-shared.svc.cluster.local:27017/admin?replicaSet=rs0&authSource=admin
```

`apps/example-app/values.yaml` already lists `MONGO_SHARED_ADMIN_URI` in `secretEnv` and sets
`SHARED_MONGO=1` + `MONGO_SHARED_HOSTS` + `MONGO_SHARED_REPLICA_SET` in `env`.

## Bring-up order & verification

1. Seal + push the `mongo-shared-secret` sealed file, then sync the `mongo-shared` app; wait for
   all 3 pods `1/1`.
2. **One-time init via member-0's localhost exception** (`$ROOT_PW` = the sealed
   `MONGO_ROOT_PASSWORD`; `$H0/$H1/$H2` = `mongo-shared-{0,1,2}.mongo-shared.mongo-shared.svc.cluster.local:27017`):
   ```sh
   kubectl -n mongo-shared exec mongo-shared-0 -- mongosh --quiet --eval "
     rs.initiate({_id:'rs0', members:[{_id:0,host:'$H0'},{_id:1,host:'$H1'},{_id:2,host:'$H2'}]});
     let t=0; while(!db.hello().isWritablePrimary && t<90){ sleep(2000); t++; }
     db.getSiblingDB('admin').createUser({user:'gcadmin', pwd:'$ROOT_PW', roles:[{role:'root',db:'admin'}]});
   "
   ```
3. Verify:
   ```sh
   kubectl -n mongo-shared exec mongo-shared-0 -- \
     mongosh -u gcadmin -p "$ROOT_PW" --authenticationDatabase admin --quiet \
     --eval 'JSON.stringify(rs.status().members.map(m=>m.stateStr))'
   # -> ["PRIMARY","SECONDARY","SECONDARY"]
   ```
4. Only THEN add `MONGO_SHARED_ADMIN_URI` + flip `SHARED_MONGO=1` and redeploy the control-plane,
   so new tenants provision onto the shared cluster.

## Runbook: majority-zone loss (RS write-unavailable)

Members sit 1×fw1 + 2×fw2 (3 members / 2 zones — a 2+1 split is unavoidable, and it's all one
DL360 anyway). **If fw2 (v615/v615b) dies, 2 of 3 members are gone → no quorum → the RS goes
READ-ONLY** (tenant Nightscouts error on writes; ingester writes fail). Recovery, in order:

1. **Prefer fixing the zone** (restart the fw2 VMs / path) — members rejoin automatically.
2. **If fw2 is gone for a while**, force the surviving member into a 1-node majority
   (accepts the risk of losing any writes the dead members had not replicated):
   ```sh
   kubectl -n mongo-shared exec mongo-shared-0 -- mongosh -u gcadmin -p "$ROOT_PW" \
     --authenticationDatabase admin --quiet --eval '
       cfg = rs.conf();
       cfg.members = cfg.members.filter(m => m.host.startsWith("mongo-shared-0"));
       cfg.version++;
       rs.reconfig(cfg, {force: true})'
   ```
   Writes resume on the single member immediately.
3. **When fw2 returns**: scale/let pods 1+2 come back, then `rs.add(...)` each host back into the
   config (or re-run the full 3-member `rs.reconfig`). They initial-sync from member-0.
4. If member-0 (fw1) was the casualty instead: quorum survives (2/3 on fw2) — no action needed
   beyond restoring the VM.

## Version bumps on a populated cluster

`mongod` refuses to start on data files from a much older major (FCV mismatch). Two paths:
stepwise official upgrades (4.4→5.0→…→8.0 with `setFeatureCompatibilityVersion` at each hop),
or — far simpler while small — `mongodump --oplog` everything, delete the StatefulSet + PVCs
(ArgoCD recreates on the new image), re-run the init above, `mongorestore --oplogReplay`.
The 2026-07-15 4.4→8.0 bump used the rebuild path (~1 tenant of data).

## Restore (from the restic repo)

```sh
restic -r /repo dump latest /work/mongo-shared.archive.gz > /tmp/a.gz   # inside a restic pod
mongorestore --host "rs0/$H0" -u gcadmin -p "$ROOT_PW" --authenticationDatabase admin \
  --gzip --archive=/tmp/a.gz --oplogReplay
```
Test the restore path periodically — an unrestored backup is a hope, not a backup.
