# Redpanda Telemetry

A Helm chart that deploys a [Grafana Alloy](https://grafana.com/docs/alloy/latest/) collector to scrape metrics and collect logs from Redpanda pods and forward them to a Redpanda observability pipeline.

## Overview

The collector discovers Redpanda pods in a configured namespace, scrapes their admin API metrics endpoints (`/metrics` and `/public_metrics`), and collects container logs. It automatically fetches the cluster UUID from the Redpanda admin API and attaches it as a `cluster_id` resource attribute on all telemetry, enabling per-cluster routing downstream.

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

### `alloy` (recommended)

Creates an Alloy Custom Resource, which is managed by the Grafana Alloy Operator. Use this if your cluster already runs the operator and you want operator-managed lifecycle.

```yaml
alloy:
   deploymentMode: "alloy"
   ```

### `direct`

Creates Kubernetes resources directly — a DaemonSet, ConfigMap, ServiceAccount, and RBAC — without requiring the Alloy operator. This is the simpler option and works on any Kubernetes cluster.

```yaml
alloy:
  deploymentMode: "direct"
```


## Transport modes

### Direct to Kafka

The collector writes telemetry directly to Redpanda Cloud Kafka topics. Topics are named dynamically using the customer name and cluster UUID:

```
{customer}-metrics-{cluster_uuid}
{customer}-logs-{cluster_uuid}
```

The cluster UUID is fetched at startup from the Redpanda admin API (`/v1/cluster/uuid`) and attached to all telemetry as `cluster_id`.

```yaml
gateway:
  enabled: false

redpanda:
  bootstrapServer: "seed-xxxxx.xxxxxxxxxxxxxxxx.byoc.prd.cloud.redpanda.com:9092"
  saslMechanism: "SCRAM-SHA-256"
```

#### Default topic failover

When `defaultTopics.enabled` is set to `true`, the collector routes to the cluster-specific topic by default but automatically falls back to `{customer}-metrics-default` / `{customer}-logs-default` if the cluster-specific topic does not exist. This is useful when a cluster is not yet provisioned in the observability backend.

Once the cluster-specific topic is created, the collector switches back automatically within the configured `retryInterval` (default: 30 seconds).

```yaml
defaultTopics:
  enabled: true
```

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

The collector fetches the Redpanda cluster UUID from the admin API at startup. By default it uses HTTPS:

```
https://redpanda-0.redpanda.<namespace>.svc.cluster.local:9644/v1/cluster/uuid
```

If your Redpanda cluster does not have TLS enabled on the admin API, set `clusterUuidEndpoint` to `"http"`:

```yaml
redpanda:
  clusterUuidEndpoint: "http"
```

## Configuration reference

| Value | Default | Description |
|-------|---------|-------------|
| `alloy.name` | `collector` | Name of the Alloy instance and Kubernetes resources |
| `alloy.namespace` | `redpanda` | Namespace to deploy the collector into |
| `alloy.deploymentMode` | `alloy` | Deployment mode: `alloy` or `direct` |
| `alloy.image` | `paulmw/alloy:v1.13.2-kafkarouter` | Alloy container image (direct mode only) |
| `customer` | — | **Required.** Customer name used to construct topic names |
| `credentials.secretName` | — | Name of the Kubernetes Secret containing `username` and `password` |
| `gateway.enabled` | `false` | Enable gateway (OTLP HTTP) transport instead of direct Kafka |
| `gateway.endpoint` | — | OTLP gateway endpoint URL |
| `gateway.tls.insecure` | `false` | Disable TLS (use plain HTTP) |
| `gateway.tls.insecure_skip_verify` | `false` | Skip TLS certificate verification |
| `gateway.credentials.secretName` | — | Gateway-specific credentials secret (falls back to `credentials.secretName`) |
| `redpanda.bootstrapServer` | — | Kafka bootstrap server (direct mode) |
| `redpanda.saslMechanism` | `SCRAM-SHA-256` | SASL mechanism: `SCRAM-SHA-256` or `SCRAM-SHA-512` |
| `redpanda.clusterUuidEndpoint` | `https` | Protocol for admin API UUID fetch: `https` or `http` |
| `redpanda.clusterUuidPod` | `redpanda-0.redpanda` | Pod and service name for UUID discovery |
| `redpanda.clusterUuidPort` | `9644` | Admin API port |
| `discovery.namespace` | `redpanda` | Namespace to discover Redpanda pods in |
| `discovery.labelSelector` | `app.kubernetes.io/name=redpanda` | Label selector for Redpanda pods |
| `defaultTopics.enabled` | `false` | Enable fallback to default topics (direct mode only) |
| `defaultTopics.failureThreshold` | `3` | Consecutive failures before switching to fallback topic |
| `defaultTopics.retryInterval` | `30s` | How often to re-probe the primary topic after failover |
| `topics.metrics` | `{customer}-metrics-{cluster_uuid}` | Override metrics topic name |
| `topics.logs` | `{customer}-logs-{cluster_uuid}` | Override logs topic name |
| `scrape.interval` | `30s` | Prometheus scrape interval |
| `scrape.timeout` | `10s` | Prometheus scrape timeout |
| `scrape.adminPort` | `9644` | Redpanda admin API port for service discovery |
| `batch.metricsBatchSize` | `5000` | Max metrics data points per batch |
| `batch.logsBatchSize` | `10000` | Max log records per batch |
| `batch.timeout` | `10s` | Max time to wait before sending a partial batch |
| `producer.metricsCompression` | `zstd` | Kafka producer compression for metrics |
| `producer.logsCompression` | `zstd` | Kafka producer compression for logs |
| `producer.metricsMaxMessageBytes` | `10485760` | Max Kafka message size for metrics (bytes) |
| `producer.logsMaxMessageBytes` | `10485760` | Max Kafka message size for logs (bytes) |
| `exportTimeout` | `30s` | Timeout for export requests |
| `exportQueue.enabled` | `true` | Enable sending queue (gateway mode) |
| `exportQueue.metricsQueueSize` | `50000` | Queue depth for metrics (gateway mode) |
| `exportQueue.logsQueueSize` | `50000` | Queue depth for logs (gateway mode) |
| `exportQueue.numConsumers` | `20` | Concurrent queue consumers (gateway mode) |

## Examples

### Direct to Kafka, with default topic failover

Use this for a cluster that may not yet be provisioned in the observability backend. Telemetry falls back to `{customer}-metrics-default` until the cluster-specific topic is created.

```yaml
customer: "acme"

alloy:
  name: collector
  namespace: redpanda
  deploymentMode: "direct"

credentials:
  secretName: "customer-acme"

discovery:
  namespace: redpanda
  labelSelector: "app.kubernetes.io/name=redpanda"

redpanda:
  bootstrapServer: "seed-xxxxx.xxxxxxxxxxxxxxxx.byoc.prd.cloud.redpanda.com:9092"
  saslMechanism: "SCRAM-SHA-256"

defaultTopics:
  enabled: true
```

### Gateway (OTLP HTTP)

Only use this when you don't have direct access to the Redpanda Cloud broker Kafka API.

```yaml
customer: "acme"

alloy:
  name: collector
  namespace: redpanda
  deploymentMode: "direct"

credentials:
  secretName: "customer-acme"

discovery:
  namespace: redpanda
  labelSelector: "app.kubernetes.io/name=redpanda"

gateway:
  enabled: true
  endpoint: "https://gateway.observability.cs.redpanda.com:443"
  tls:
    insecure: false
    insecure_skip_verify: false
```

### Non-TLS admin API (self-managed or local clusters)

If the Redpanda admin API is not TLS-enabled, set `clusterUuidEndpoint: "http"` to prevent a startup failure when the collector attempts HTTPS discovery.

```yaml
redpanda:
  clusterUuidEndpoint: "http"
```

## Troubleshooting

### Collector fails to start with `json_decode unexpected end of JSON input`

The collector could not fetch the cluster UUID from the admin API. This usually means the admin API is using plain HTTP but `clusterUuidEndpoint` is set to `https` (the default). Set `redpanda.clusterUuidEndpoint: "http"` in your values file.

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

### Metrics stuck on default topics after cluster provisioning

In direct mode with `defaultTopics.enabled: true`, the collector probes the cluster-specific topic every `defaultTopics.retryInterval` (default: 30 seconds). Once the topic exists, it switches back automatically. No restart is required.
