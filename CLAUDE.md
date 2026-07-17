# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Helm chart (`redpanda-o11y`, repo name `redpanda-telemetry`) that deploys a Grafana Alloy
collector to scrape Redpanda broker metrics/logs and ship them to Kafka (direct mode) or a central
OTLP gateway (gateway mode). There is no application code here — the chart *is* the product. The
real logic lives inside Alloy config strings embedded in the Helm templates, written in Alloy's
River-like syntax, not Go/YAML logic.

## Hard dependency: the custom Alloy fork

This chart requires a custom-built Alloy image (`paulmw/alloy:v1.17.1-rp` by default, see
`alloy.image` in `values.yaml`), built from a private fork of `grafana/alloy` that adds three
components this chart depends on directly:

- `discovery.redpanda` — enriches discovered pod targets with per-pod Redpanda cluster UUIDs and
  decides, via an embedded Raft group, which collector replica scrapes which broker.
- `otelcol.exporter.kafka_router` — routes OTLP metrics/logs to per-customer/per-cluster Kafka
  topics with template-based fallback.
- `otelcol.processor.metricsbatcher` — batches metrics without splitting a histogram family
  (`_bucket`/`_sum`/`_count`) across batches.

A stock/upstream Alloy image does not have these components and the collector will fail to start.
The fork lives in a sibling repo at `../../alloy` (relative to this chart) — its `CLAUDE.md` is the
source of truth for exact component names, arguments, and the fork's tagging convention
(`<upstream-release>-rp`). Component names have changed before (`discovery.redpanda_uuid` →
`discovery.redpanda`, `otelcol.processor.groupbatch` → `otelcol.processor.metricsbatcher`) — always
check the fork's `CLAUDE.md` component table rather than assuming names in this chart are current.

## Commands

```bash
helm lint .                                   # static validation
helm template . -f <values-file>              # render manifests, no cluster needed
helm template . -f <values-file> -s templates/direct-configmap.yaml   # render just the Alloy config
helm install <release> . -n <namespace> -f <values-file> --dry-run    # render against a live context (needed for anything using `lookup`)
helm upgrade --install <release> . -n <namespace> -f <values-file>    # actual install/upgrade
```

There is no automated test suite or CI config in this repo. Verification is: `helm lint`, then
`helm template` to read the rendered Alloy config by eye, then (for real confidence) an actual
`helm install`/`upgrade` against a real or `kind` cluster, checking `kubectl logs <pod> -c alloy`
for `level=error` lines and for `node_id=` evaluation of the three custom components above, plus
`producing record` / `produced to fallback topic` lines from `otelcol.exporter.kafka_router`.

**kubeconfig gotcha:** if testing against a local `kind` cluster, always check
`kubectl config current-context` before installing anything — a kubeconfig here may default to a
real EKS context. `kubectl config use-context kind` before any test install/upgrade.

## Architecture

### Two deployment modes, one Alloy config, duplicated across templates

`alloy.deploymentMode` picks between:
- `"alloy"` (default) → `templates/alloy.yaml` creates an `Alloy` CRD, reconciled by the Grafana
  Alloy Operator into the actual StatefulSet.
- `"direct"` → `templates/direct-*.yaml` (ServiceAccount, ClusterRole/Binding, ConfigMap,
  StatefulSet+headless Service) create everything directly, no operator required.

Both modes embed **the same Alloy pipeline** (discovery → relabel → scrape → cluster_id enrichment
→ batch → export) as a config string — `templates/alloy.yaml`'s `spec.alloy.configMap.content` and
`templates/direct-configmap.yaml`'s `data["config.alloy"]` are near-duplicates of each other. **A
pipeline change (new component, changed routing, new relabel rule) needs to be made in both files**
— there is no shared partial for the Alloy config body itself, only for small Helm-level helpers in
`_helpers.tpl`.

The collector always runs as a StatefulSet — `alloy.controllerType` was removed (was `Deployment`/
`DaemonSet`/`StatefulSet`). Deployment and DaemonSet pods never get the
`apps.kubernetes.io/pod-index` label that the sharding logic below depends on, so those modes were
already non-functional for anything beyond a single replica; don't reintroduce them without also
solving that.

### Broker allocation via embedded Raft, not pod ordinal

`discovery.redpanda` decides which collector replica scrapes which Redpanda broker itself, via a
Raft group embedded in the component (one voter per Alloy replica, membership driven by Alloy's
own gossip clustering). The Raft leader assigns brokers to the least-loaded eligible collector,
rebalances when a replica joins or leaves, and prefers not putting two brokers from the same
Redpanda cluster on one collector. There's no pod-ordinal or `POD_INDEX` involvement at all
anymore — every replica's `discovery.redpanda` output already reflects final ownership, so nothing
downstream needs to relabel-filter by shard. Set `alloy.replicas` to roughly the total broker count
across all monitored namespaces to get close to a 1:1 split; fewer replicas just means each
collector owns more brokers.

This requires:
- Alloy's native clustering enabled (`--cluster.enabled`, `--cluster.join-addresses`,
  `--cluster.wait-for-size`) — `discovery.redpanda` reads `cluster.Peers()`/`cluster.Ready()` to
  bridge gossip membership into its own Raft voter set.
- A dedicated Raft RPC port (`raft_bind_port`, default `9700`) on both the container and the
  headless Service, separate from Alloy's own clustering port.
- `serviceName` set on the StatefulSet, so pods get the per-pod DNS names
  (`<pod>.<service>.<namespace>.svc.cluster.local`) Raft peers use to address each other — a plain
  pod IP goes stale across a restart, which DNS doesn't.
- A namespaced `Role`/`RoleBinding` granting the Alloy ServiceAccount `get`/`create` on ConfigMaps
  (`templates/direct-role.yaml`). Every collector pod's Raft state is deliberately ephemeral — no
  PVC, nothing persisted to disk — so on every restart, a replica has to decide fresh whether it's
  safe to bootstrap a new Raft cluster or whether a real one already exists. That decision is made
  by atomically creating a well-known marker ConfigMap (`<statefulset>-raft-bootstrapped`):
  Kubernetes' `Create` is atomic at the API server, so exactly one replica ever wins the race no
  matter how many restart at once or how inconsistent their gossip views of each other are — a
  replica that loses just waits to be added as a Raft voter by whoever already has.

### Multi-cluster cluster_id discovery

`discovery.redpanda` queries each pod's *own* admin API directly (`https://<pod-ip>:9644/v1/cluster/uuid`)
during discovery and caches permanently (a cluster's UUID never changes). This is what makes it
safe to point `discovery.namespaces` at several distinct Redpanda clusters at once, even if they
share a namespace — each pod gets its own cluster's UUID rather than one UUID being assumed for
everything discovered.

### Topic routing (direct mode) is fixed, not configurable

`otelcol.exporter.kafka_router` always routes to `{customer}-{metrics|logs}-{cluster_id}`, falling
back per-produce-attempt to `{customer}-{metrics|logs}-default` if that topic doesn't exist yet —
this is unconditional, stateless (no "sticky" fallback), and not gated by any values key. There used
to be `topics.metrics`/`topics.logs` override keys and a `defaultTopics.enabled` toggle in an earlier
iteration of this chart; both are gone and have no effect if set. Compression is fixed at the
component's `zstd` default — the chart doesn't expose a `compression` attribute even though the
underlying `otelcol.exporter.kafka_router` component supports one.

### Credentials: customer-scoped, not per-cluster

One Kubernetes Secret per customer (`username`/`password` keys) authenticates to every cluster that
customer owns, enforced via Redpanda PREFIXED ACLs on `<customer>-` topic names (see
`CREDENTIALS.md`). Direct mode uses SASL/SCRAM with these credentials read from env vars
(`KAFKA_USERNAME`/`KAFKA_PASSWORD`, populated via `secretKeyRef` at pod start). Gateway mode uses the
same credentials for HTTP Basic Auth by default, or a separate `gateway.credentials` secret/literal
if set — also via env vars (`GATEWAY_USERNAME`/`GATEWAY_PASSWORD`). Keep any new
credential-consuming component on this env-var pattern rather than a Helm-render-time `lookup` on
the Secret — `lookup` requires a live cluster connection just to `helm template` the chart and bakes
plaintext credentials into the rendered ConfigMap.

### Where things are documented

- `values.yaml` — every option, heavily commented, meant to be read top-to-bottom as the primary
  reference.
- `README.md` — deployment modes, transport modes, full config table, worked examples,
  troubleshooting.
- `CREDENTIALS.md` — the customer/ACL credential model in depth.
- `CHANGELOG.md` — what changed and what upgraders must do, per chart version. Keep this current
  when making a breaking values change; it's the only place that explains *why* an old key was
  removed rather than just that it was.
