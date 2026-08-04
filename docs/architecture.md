# Architecture

## Two domains need a third

The requirement was ordinary and the consequence is not: two independent failure domains, each
behind its own firewall, each able to go down for maintenance at short notice.

Kubernetes stores cluster state in etcd, which needs a **majority** of control-plane members to
accept a write. Split an even number of members evenly across two sites and neither side holds a
majority when the link or a firewall fails. The cluster does not fail over — it freezes. Nothing
schedules, nothing reconciles, and the surviving half is just as stuck as the dead one.

Two sites cannot break their own tie. The tiebreaker has to live somewhere that neither site can
take down with it.

```
        FAILURE DOMAIN A                 FAILURE DOMAIN B
        (behind firewall 1)              (behind firewall 2)
     ┌──────────────────────┐         ┌──────────────────────┐
     │  node a1  (worker)   │         │  node b1  (worker)   │
     │  node a2  (worker)   │         │  node b2  (worker)   │
     └──────────┬───────────┘         └───────────┬──────────┘
                │                                 │
                └──────────────┬──────────────────┘
                               │
                    ┌──────────┴───────────┐
                    │   THIRD DOMAIN       │
                    │   control-plane      │   ← breaks the tie
                    │   tiebreaker (cloud) │
                    └──────────────────────┘

   lose domain A  →  B + tiebreaker keep quorum   ✅
   lose domain B  →  A + tiebreaker keep quorum   ✅
   lose the tiebreaker → A + B still hold quorum  ✅
```

Four worker/server nodes split evenly, plus one control-plane member in a third domain. Any single
domain can disappear and the cluster keeps making decisions.

!!! tip "The general lesson"
    Any even split across two sites has this problem. If you cannot add a third site, the honest
    alternatives are a designated primary that stays up, or accepting that maintenance on either
    side is a cluster outage. "Two-site HA" without a tiebreaker is a stated intention, not a
    property.

## Spread the stateless, pin the stateful

Once quorum survives, the question becomes where individual workloads go — and the answer differs
by whether the workload has state.

### Stateless: spread

Nodes carry a `platform.zone` label, and stateless replicas are spread across it using topology
spread constraints. The chart exposes this per app:

```yaml
placement:
  zoneSpread: true            # spread replicas across platform.zone
  zoneSpreadRequired: false   # hard vs soft
  zoneLabel: platform.zone
```

`zoneSpreadRequired` is the setting that actually matters, and it is a real trade:

| | `false` (soft) | `true` (hard) |
|---|---|---|
| Scheduler behaviour | *prefers* an even spread | `DoNotSchedule` + `maxSurge: 0` |
| One firewall holds every replica? | possible | prevented |
| Rolling restarts | always proceed | can block if a zone is full |
| Replicas per zone | unbounded | effectively capped |

Soft spreading is the sensible default because a scheduler that refuses to place a pod is its own
kind of outage. But soft means *preferred*, and during a rolling restart the scheduler will happily
collapse both replicas onto whichever node is emptier — which is exactly the situation the spread
existed to prevent. If an app genuinely must survive losing one firewall, it needs
`zoneSpreadRequired: true` and enough headroom for the restart.

### Stateful: pin

Databases do not get spread. They get a zone:

```yaml
placement:
  dbZone: ""                 # e.g. "fw2" — pins stateful services to one zone's data node
  dataLabel: platform.data   # nodes that may host PVCs carry platform.data=true
```

A local PersistentVolume is bound to the node that provides it. A database that "wanders" between
failure domains does not become more available — it becomes a database whose data is on a node it
is no longer running on. Pinning is not a limitation being worked around; it is the correct answer
for local storage.

`platform.data` is a second, independent label: it marks which nodes may host PVCs at all. Zone
says *which side*, data says *whether this node has storage worth binding to*.

## Encrypt across the boundary

The third piece follows from the second. If the database is pinned to one zone, its backups must
not be:

```yaml
backup:
  zone: ""   # pin the restic repo PVC to a DIFFERENT platform.zone than the DB
```

Backups pinned to the same zone as the database are not backups. They are a second copy of the
thing you are about to lose. The repository PVC is deliberately placed in the *other* domain, and
the contents are encrypted so the recovery path never depends on the zone that just failed.

See [Operations → Backups](operations.md#backups) for the mechanics.

## Pod DNS, and one non-obvious setting

```yaml
dns:
  ndots: "1"
```

Kubernetes defaults to `ndots: 5`, which means any name with fewer than five dots is tried against
the cluster search domains *first*. That is usually invisible — until a node's search domain
contains a wildcard record. Then an outbound lookup for a legitimate external FQDN matches the
wildcard and gets hijacked before it ever reaches public DNS.

Setting `ndots: 1` resolves external FQDNs absolute-first. Single-label in-cluster service names
still resolve through the search list, so nothing in-cluster breaks.

## Portability

Nothing above is k3s-specific. The zone and data labels are ordinary node labels, the spread
constraints are standard Kubernetes, and the charts render plain manifests. The k3s-shaped
decisions are confined to defaults — `storageClassName: ""` picking up `local-path`, and
`ingress.className: ""` picking up the bundled Traefik — both of which are values, not templates.
