# Changelog

All notable changes to this chart are documented in this file.

## [0.2.0]

### Action required when upgrading from 0.1.0

- **`discovery.namespace` → `discovery.namespaces`.** Single-namespace discovery has been replaced
  by a list, so multiple Redpanda clusters can be monitored by one collector. If you previously set
  `discovery.namespace: my-ns`, change it to:
  ```yaml
  discovery:
    namespaces:
      - my-ns
  ```
  The old key is silently ignored — the chart will fall back to the release namespace if you don't migrate it.

- **`alloy.replicas` is no longer auto-detected.** 0.1.0 defaulted to the replica count of the
  Redpanda StatefulSet it discovered (falling back to 1). 0.2.0 has no cluster to look up by default
  (since discovery can span several namespaces/clusters) and defaults to a static `3`. Set
  `alloy.replicas` explicitly to match your broker count — sharding across collector pods depends on it.

- **`discovery.containerName` and `discovery.appName` have been removed.** These were used to filter
  sidecar containers out of log collection and to override the derived app name for non-standard
  release names. There is no replacement in this release.

- **`alloy.controllerType` has been removed — the direct-mode collector always runs as a
  StatefulSet now.** `Deployment` and `DaemonSet` are gone: neither Deployment nor DaemonSet pods
  get the `apps.kubernetes.io/pod-index` label that the collector's broker-sharding logic depends
  on, so both were already non-functional for any `alloy.replicas` beyond a single instance. If you
  had `alloy.controllerType: Deployment` or `DaemonSet` set, remove it — it's now a no-op key.

- **`producer.metricsCompression` / `producer.metricsMaxMessageBytes` / `producer.logsCompression` /
  `producer.logsMaxMessageBytes` have been removed**, along with `topics.metrics`, `topics.logs`, and
  `exportTimeout`. These only applied to the old direct Kafka exporter path (see below) and have no
  effect now. The new equivalent is `producer.maxBatchBytes` (default `10485760`, i.e. 10 MiB).
  Per-signal topic names are no longer configurable — see "Kafka export" below.
  Compression is not currently exposed as a value at all: `otelcol.exporter.kafka_router` supports a
  `compression` attribute (`zstd`/`snappy`/`lz4`/`gzip`/`none`), but the chart doesn't set it, so it
  always uses the component's default, `zstd`. There is no way to change or disable compression in
  this release.

### Changed

- **Kafka export path replaced with `otelcol.exporter.kafka_router`.** Direct-mode (non-Gateway)
  metrics and logs no longer go through separate `otelcol.exporter.kafka` + `otelcol.connector.failover`
  pairs per signal. A single `otelcol.exporter.kafka_router` component now handles routing, with the
  same effective topic naming as before: `<customer>-<signal>-<cluster_id>`, falling back to
  `<customer>-<signal>-default` if the cluster-specific topic doesn't exist.
- **Cluster UUID discovery moved from a per-pod `remote.http` poll to the `discovery.redpanda`
  component**, which enriches discovered pod targets with their Redpanda cluster UUID and a stable
  pod ordinal directly during discovery, instead of polling one pod's admin API on a timer. This also
  removes the need for the `appName`-based URL template that `remote.http` relied on.
  (Renamed from `discovery.redpanda_uuid` during development — see the Alloy fork's `CLAUDE.md` for
  the up-to-date component table.)
  - Note: `discovery.redpanda` requires the custom Alloy build below — a stock/upstream Alloy image
    will not have this component and the collector will fail to start.
- **Metrics batching processor renamed** from `otelcol.processor.groupbatch` to
  `otelcol.processor.metricsbatcher` (same behavior — keeps all data points for the same
  resource/metric-name group together so histogram families aren't split across batches).
- **Default Alloy image bumped to `paulmw/alloy:v1.17.1-rp`** (from `paulmw/alloy:v1.13.2-kafkarouter-24`).
  If you pin `alloy.image` explicitly, update it to an image built from this or a later fork release —
  see the Alloy fork's `CLAUDE.md` for the tagging and build convention.
- **RBAC (`ClusterRole`) scope narrowed** to only what discovery and log collection actually use
  (pods, namespaces, pod logs). Broader permissions the collector never used (secrets, events, nodes,
  Prometheus Operator CRDs, non-resource `/metrics`, etc.) have been dropped. No action needed — Helm
  updates the `ClusterRole` in place on upgrade.

### Added

- `logs.parseSeverity` (default `true`) — parses a `TRACE`/`DEBUG`/`INFO`/`WARN`/`ERROR`/`FATAL`
  prefix out of the log body and sets it as the OTLP severity level. Set to `false` on very
  high-volume clusters where the per-record OTTL cost is measurable.
- `alloy.logLevel` (default `"info"`) — Alloy's own log level.
- `alloy.liveDebugging` (default `false`) — enables the Alloy UI's live data inspector. Not
  recommended for production.
- `alloy.maxUnavailable` (defaults to `alloy.replicas`) — caps how many collector pods can be down
  at once during a rolling update, for canary-style rollout protection.

## [0.1.0]

Initial public release.
