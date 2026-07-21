# redpanda-o11y

A Helm chart that deploys a [Grafana Alloy](https://grafana.com/docs/alloy/latest/) collector to scrape metrics and collect logs from Redpanda pods and forward them to a Redpanda observability pipeline.

## Overview

The collector discovers Redpanda pods across one or more configured namespaces, scrapes their admin API metrics endpoints (`/metrics` and `/public_metrics`), and collects container logs. During discovery, each pod is queried directly for its cluster UUID, which is attached as a `cluster_id` resource attribute on all telemetry from that pod — this works correctly even when multiple Redpanda clusters are discovered by the same collector.

Telemetry is forwarded using one of two transport modes:

- **Direct (Kafka)** — the collector writes metrics and logs directly to Redpanda Cloud Kafka topics using SASL/SCRAM authentication.
- **Gateway (OTLP HTTP)** — the collector forwards telemetry to a central OTLP gateway over HTTPS with Basic Auth. The gateway handles routing to the appropriate Kafka topics.

## Prerequisites

- Kubernetes cluster with Redpanda deployed
- A Kubernetes Secret containing `username` and `password` keys for authentication (refer to [Credentials](#credentials))
- **Direct mode**: Redpanda Cloud BYOC cluster with topics and ACLs provisioned for this customer
- **Gateway mode**: Access to the OTLP gateway endpoint
- **Alloy operator deployment mode**: [Grafana Alloy Operator](https://grafana.com/docs/alloy/latest/get-started/install/kubernetes/) installed in the cluster

## Deployment modes

The chart supports two deployment modes, controlled by `alloy.deploymentMode`.

### `direct` (recommended)

Creates Kubernetes resources directly — a StatefulSet, ConfigMap, ServiceAccount, and RBAC — without requiring the Alloy operator. This is the simpler option and works on any Kubernetes cluster.

The collector always runs as a StatefulSet: every discovered Redpanda pod (across all configured `discovery.namespaces`) is assigned a stable global ordinal, and collector pod `N` scrapes only the Redpanda pods whose ordinal modulo `alloy.replicas` equals `N`. Set `alloy.replicas` to the total number of brokers being monitored across all namespaces for an even, non-overlapping 1-to-1 split; a smaller value shards multiple brokers onto each collector pod instead.

```yaml
alloy:
  deploymentMode: "direct"
  replicas: 3
```

### `alloy`

Creates an Alloy Custom Resource, which is managed by the Grafana Alloy Operator. Use this if your cluster already runs the operator and you want operator-managed lifecycle.

```yaml
alloy:
  deploymentMode: "alloy"
```

## Transport modes

### Direct to Kafka

The collector writes telemetry directly to Redpanda Cloud Kafka topics. Topics are named dynamically using the customer name and cluster UUID:

```
{customer}-metrics-{cluster_id}
{customer}-logs-{cluster_id}
```

The cluster UUID is discovered per-pod (see [Cluster UUID discovery](#cluster-uuid-discovery) below) and attached to all telemetry as `cluster_id`.

```yaml
gateway:
  enabled: false

redpanda:
  bootstrapServer: "seed-xxxxx.xxxxxxxxxxxxxxxx.byoc.prd.cloud.redpanda.com:9092"
  saslMechanism: "SCRAM-SHA-256"
```

#### Default topic fallback

Every produce attempt tries the cluster-specific topic first. If that produce fails (e.g. because the cluster isn't yet provisioned in the observability backend and the topic doesn't exist), the collector retries that same batch on `{customer}-metrics-default` / `{customer}-logs-default`. This is always on and isn't configurable — there's no `defaultTopics.enabled` toggle. Once the cluster-specific topic exists, the very next produce succeeds against it directly; there's no sticky fallback state to reset or wait out.

### Gateway (OTLP HTTP)

The collector forwards telemetry to a central OTLP gateway via HTTPS with Basic Auth. The gateway handles routing to the appropriate Kafka topics based on the `cluster_id` attribute. For unknown clusters, the gateway routes to the customer's default topics.

```yaml
gateway:
  enabled: true
  endpoint: "https://gateway.observability.cs.redpanda.com:443"
```

## Installation

### 1. Create the credentials secret

Create a Kubernetes Secret in the namespace where the collector will run:

```sh
kubectl create secret generic customer-<name> \
  --namespace <namespace> \
  --from-literal=username=<username> \
  --from-literal=password=<password>
```

Or apply a pre-created secret manifest:

```sh
kubectl apply -f customer-<name>.yaml
```

### 2. Create a values file

Create a values file for your deployment. Refer to the [examples](#examples) below.

### 3. Install the chart

```sh
helm install <release-name> redpanda-o11y -f my-values.yaml
```

To upgrade an existing release:

```sh
helm upgrade <release-name> redpanda-o11y -f my-values.yaml
```

## Credentials

Authentication credentials are read from a Kubernetes Secret. The Secret must exist in the same namespace as the collector and contain `username` and `password` keys.

```yaml
credentials:
  secretName: "customer-<name>"
```

In direct (Kafka) mode, the credentials are used for SASL/SCRAM authentication to the Redpanda Cloud broker.

In gateway mode, the credentials are used for HTTP Basic Auth to the OTLP gateway. You can optionally specify separate gateway credentials:

```yaml
gateway:
  enabled: true
  endpoint: "https://gateway.observability.cs.redpanda.com:443"
  credentials:
    secretName: "customer-<name>-gateway"
```

If `gateway.credentials` is not set, the collector uses the main `credentials` section for gateway authentication.

## Cluster UUID discovery

During pod discovery, the collector queries each discovered Redpanda pod's own admin API directly (`<pod-ip>:9644/v1/cluster/uuid` by default) for its cluster UUID. Each pod is enriched with its own UUID individually, so multiple Redpanda clusters can be discovered and routed correctly by the same collector, even when they share a namespace. UUIDs are cached for the lifetime of the collector process, since a cluster's UUID never changes.

Whether each pod's admin API speaks TLS is detected automatically — the collector tries `https` first, falls back to `http`, and remembers whichever one worked for that pod. No configuration needed, and a fleet monitoring multiple Redpanda clusters doesn't need them to be uniformly TLS or plaintext.

## Configuration reference

| Value | Default | Description |
|-------|---------|-------------|
| `alloy.name` | `collector` | Name of the Alloy instance and Kubernetes resources |
| `alloy.namespace` | `redpanda` | Namespace to deploy the collector into |
| `alloy.deploymentMode` | `alloy` | Deployment mode: `alloy` or `direct` |
| `alloy.replicas` | `3` | Replica count. Set this to the total number of brokers being monitored across all `discovery.namespaces` — see [Deployment modes](#direct-recommended) |
| `alloy.logLevel` | `info` | Alloy's own log level: `error`, `warn`, `info`, or `debug` |
| `alloy.liveDebugging` | `false` | Enable the Alloy UI's live data inspector. Not recommended for production |
| `alloy.maxUnavailable` | `alloy.replicas` | Max pods unavailable during a rolling update (StatefulSet only) |
| `alloy.image` | `paulmw/alloy:v1.17.1-rp-0.2.0-dev` | Alloy container image. Must be built from this fork (or a later release of it) — a stock/upstream Alloy image won't have the custom components this chart depends on |
| `customer` | — | **Required.** Customer name used to construct topic names |
| `credentials.secretName` | — | Name of the Kubernetes Secret containing `username` and `password` |
| `gateway.enabled` | `false` | Enable gateway (OTLP HTTP) transport instead of direct Kafka |
| `gateway.endpoint` | — | OTLP gateway endpoint URL |
| `gateway.protocol` | `http` | Gateway protocol: `http` or `grpc` |
| `gateway.tls.insecure` | `false` | Disable TLS (use plain HTTP) |
| `gateway.tls.insecure_skip_verify` | `false` | Skip TLS certificate verification |
| `gateway.credentials.secretName` | — | Gateway-specific credentials secret (falls back to `credentials.secretName`) |
| `redpanda.bootstrapServer` | — | Kafka bootstrap server (direct mode) |
| `redpanda.saslMechanism` | `SCRAM-SHA-256` | SASL mechanism: `SCRAM-SHA-256` or `SCRAM-SHA-512` |
| `discovery.namespaces` | `[<release namespace>]` | List of namespaces to discover Redpanda pods in. Add multiple entries to monitor several clusters with one collector |
| `discovery.labelSelector` | `app.kubernetes.io/name=redpanda` | Label selector for Redpanda pods |
| `discovery.adminPort` | `9644` | Redpanda admin API port, used for scrape discovery and per-pod UUID lookup |
| `discovery.scrapeInterval` | `30s` | Prometheus scrape interval |
| `discovery.scrapeTimeout` | `10s` | Prometheus scrape timeout |
| `logs.parseSeverity` | `true` | Parse a `TRACE`/`DEBUG`/`INFO`/`WARN`/`ERROR`/`FATAL` prefix out of the log body and set it as the OTLP severity. Disable on very high-volume clusters where the per-record cost is measurable |
| `batch.metricsBatchMaxSize` | `5000` | Max metrics data points per batch |
| `batch.logsBatchSize` | `10000` | Max log records per batch |
| `batch.timeout` | `2s` | Max time to wait before flushing a partial batch (shared by metrics and logs) |
| `producer.maxBatchBytes` | `10485760` | Max Kafka RecordBatch size in bytes (direct mode). Must not exceed the broker's `kafka_batch_max_bytes` |
| `exportQueue.enabled` | `true` | Enable sending queue when `exportQueue` is configured (gateway mode) |
| `exportQueue.metricsQueueSize` | `50000` | Queue depth for metrics (gateway mode) |
| `exportQueue.logsQueueSize` | `50000` | Queue depth for logs (gateway mode) |
| `exportQueue.numConsumers` | `20` | Concurrent queue consumers (gateway mode) |

Compression for direct-mode Kafka export is not currently exposed as a value — it's fixed at `zstd`.

## Examples

### Direct to Kafka

Telemetry is routed to the cluster-specific topic, falling back to `{customer}-metrics-default` / `{customer}-logs-default` if that cluster isn't yet provisioned in the observability backend — see [Default topic fallback](#default-topic-fallback).

```yaml
customer: "acme"

alloy:
  name: collector
  namespace: redpanda
  deploymentMode: "direct"
  replicas: 3

credentials:
  secretName: "customer-acme"

discovery:
  namespaces:
    - redpanda
  labelSelector: "app.kubernetes.io/name=redpanda"

redpanda:
  bootstrapServer: "seed-xxxxx.xxxxxxxxxxxxxxxx.byoc.prd.cloud.redpanda.com:9092"
  saslMechanism: "SCRAM-SHA-256"
```

### Direct to Kafka, monitoring multiple clusters

One collector can discover and route telemetry for several Redpanda clusters at once. Set `alloy.replicas` to the total broker count across all of them for an even, non-overlapping shard.

```yaml
customer: "acme"

alloy:
  name: collector
  namespace: collector
  deploymentMode: "direct"
  replicas: 9 # 3 clusters x 3 brokers each

credentials:
  secretName: "customer-acme"

discovery:
  namespaces:
    - cluster-a
    - cluster-b
    - cluster-c
  labelSelector: "app.kubernetes.io/component=redpanda"

redpanda:
  bootstrapServer: "seed-xxxxx.xxxxxxxxxxxxxxxx.byoc.prd.cloud.redpanda.com:9092"
  saslMechanism: "SCRAM-SHA-256"
```

### Gateway (OTLP HTTP)

Use this when you don't have direct access to the Redpanda Cloud broker, or when centrally managing topic routing at the gateway.

```yaml
customer: "acme"

alloy:
  name: collector
  namespace: redpanda
  deploymentMode: "direct"

credentials:
  secretName: "customer-acme"

discovery:
  namespaces:
    - redpanda
  labelSelector: "app.kubernetes.io/name=redpanda"

gateway:
  enabled: true
  endpoint: "https://gateway.observability.cs.redpanda.com:443"
  tls:
    insecure: false
    insecure_skip_verify: false
```

## Troubleshooting

### Pods discovered but missing `cluster_id` / no telemetry from a specific cluster

Look for `failed to fetch cluster UUID` warnings in the collector logs:

```sh
kubectl logs -n <namespace> -l app.kubernetes.io/name=alloy -c alloy | grep "cluster UUID"
```

This means neither an `https` nor an `http` attempt against that pod's `discovery.adminPort` got a valid response — most likely the pod isn't actually reachable there yet (still starting, wrong port), not a scheme mismatch: which scheme to use is detected automatically per pod, not configured. Targets with an unresolved UUID are excluded from scraping/log collection (with a warning), not fatal — the collector keeps running and shipping telemetry for every other pod.

### No metrics appearing in Grafana

1. Verify the Redpanda pods are running and discoverable:
   ```sh
   kubectl get pods -n <namespace> -l app.kubernetes.io/name=redpanda
   ```

2. Check the collector logs for scrape errors:
   ```sh
   kubectl logs -n <namespace> -l app.kubernetes.io/name=alloy -c alloy
   ```

3. In direct mode, verify the Kafka topics exist and the credentials have write ACLs.

4. In gateway mode, verify the gateway endpoint is reachable and the credentials are correct.

### Metrics landing on `-default` topics after cluster provisioning

This is expected during the window before a cluster's topics are provisioned — see [Default topic fallback](#default-topic-fallback). There's no persistent fallback state: once the cluster-specific topic exists, the next produce attempt goes straight to it. No restart is required.
