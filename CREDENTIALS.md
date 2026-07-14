# Credentials Architecture

## Overview

The collector uses **customer-based credentials** for both gateway mode and direct-to-Kafka mode. This provides a consistent authentication model across deployment patterns.

## Customer Credentials

### What are customer credentials?

Customer credentials are shared across all clusters owned by a single customer:
- **Username**: Customer name (e.g., `pmw`)
- **Password**: Random generated password
- **Scope**: Can write to all clusters owned by the customer

### Why customer credentials?

1. **Simplified management**: One credential set per customer instead of per cluster
2. **Scalable**: Add new clusters without creating new credentials
3. **Consistent**: Same credentials work for gateway mode and direct mode
4. **ACL-based isolation**: Redpanda ACLs use PREFIXED patterns to allow customers to write to their topics

## Credential Usage

### Gateway Mode

```yaml
# Customer name (required) - used to construct topic names
customer: "pmw"

credentials:
  secretName: "customer-pmw"  # Customer credentials

gateway:
  enabled: true
  endpoint: "https://gateway.observability.cs.redpanda.com:443"
  # Gateway uses credentials from 'credentials' section above
```

**Authentication flow:**
1. Collector authenticates to gateway using customer credentials (HTTP Basic Auth)
2. Gateway authenticates to Kafka using dedicated "gateway" user credentials
3. Gateway routes data to dynamically constructed topics

**Topic construction:**
- Topics are automatically constructed at runtime: `{customer}-metrics-{cluster_id}` and `{customer}-logs-{cluster_id}`
- Cluster ID is dynamically fetched from Redpanda API (`/v1/cluster/uuid`)
- Example: `pmw-metrics-68e2368c-87d6-436a-8132-bc55be44950f`

**Cluster ID discovery:**
- The collector automatically fetches the actual cluster UUID from the Redpanda API
- This UUID is used for both topic construction and as a `cluster_id` resource attribute

### Direct Mode

```yaml
# Customer name (required) - used to construct topic names
customer: "pmw"

credentials:
  secretName: "customer-pmw"  # Customer credentials

gateway:
  enabled: false

redpanda:
  bootstrapServer: "seed-xxx.byoc.prd.cloud.redpanda.com:9092"
```

**Authentication flow:**
1. Collector authenticates directly to Kafka using customer credentials (SASL/SCRAM-SHA-256)
2. Collector writes to dynamically constructed topics

**Topic construction:**
- Same as gateway mode - topics constructed at runtime from customer name and cluster ID
- No configuration needed beyond customer name

## Secret Format

Customer secrets must contain two keys:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: customer-pmw
type: Opaque
data:
  username: <base64-encoded-customer-name>
  password: <base64-encoded-password>
```

Example:
```bash
kubectl create secret generic customer-pmw \
  --from-literal=username=pmw \
  --from-literal=password='Y2A9&$2jWt6Hn55c6Y+-KMM%ydU5A%5)' \
  -n <namespace>
```

## Redpanda ACL Configuration

Customer credentials work because of PREFIXED ACLs in Redpanda:

```hcl
# Customer can write to all their logs topics
resource "redpanda_acl" "customer_write_logs" {
  resource_type         = "TOPIC"
  resource_name         = "pmw-logs-"      # Prefix
  resource_pattern_type = "PREFIXED"
  principal             = "User:pmw"
  host                  = "*"
  operation             = "WRITE"
  permission            = "ALLOW"
}

# Customer can write to all their metrics topics
resource "redpanda_acl" "customer_write_metrics" {
  resource_type         = "TOPIC"
  resource_name         = "pmw-metrics-"   # Prefix
  resource_pattern_type = "PREFIXED"
  principal             = "User:pmw"
  host                  = "*"
  operation             = "WRITE"
  permission            = "ALLOW"
}
```

This allows customer `pmw` to write to:
- `pmw-logs-68e2368c-87d6-436a-8132-bc55be44950f`
- `pmw-logs-565f7477-f252-41af-b1a7-57b5751dfe0a`
- `pmw-metrics-68e2368c-87d6-436a-8132-bc55be44950f`
- `pmw-metrics-565f7477-f252-41af-b1a7-57b5751dfe0a`
- ... and any other topics with the customer prefix

## Topic Naming Convention

Topics follow the pattern: `{customer}-{type}-{cluster_id}`

Examples:
- `pmw-metrics-68e2368c-87d6-436a-8132-bc55be44950f`
- `pmw-logs-565f7477-f252-41af-b1a7-57b5751dfe0a`
- `acme-metrics-12345678-1234-1234-1234-123456789012`

**Note:** Topic names are always constructed dynamically from the customer name and cluster UUID — there is no way to override them with an explicit topic name in this release.

## Cluster ID Discovery

The collector queries each discovered Redpanda pod's own admin API directly for its cluster UUID:
- **Endpoint**: `https://<pod-ip>:9644/v1/cluster/uuid` (one request per discovered pod, not a single fixed hostname)
- **Caching**: Permanent for the life of the collector process — a cluster's UUID never changes
- **Usage**: Added as `cluster_id` resource attribute to all metrics and logs from that pod
- **Configuration**: No configuration required — cluster ID is discovered automatically, and this also correctly handles multiple Redpanda clusters sharing a namespace, since each pod is enriched with its own cluster's UUID individually

This means you don't need to specify the cluster ID anywhere in your configuration. The collector will:
1. Fetch each pod's UUID directly from its own admin API during discovery
2. Attach it as metadata to all telemetry data from that pod
3. Ensure the cluster_id is always accurate, even if the cluster is replaced

## Credential Precedence

The Helm chart evaluates credentials in this order:

1. **Gateway mode**:
   - `gateway.credentials.secretName` → `gateway.credentials.username/password` → `credentials.secretName` → `credentials.username/password`

2. **Direct mode**:
   - `credentials.secretName` → `credentials.username/password`

**Important:** Credentials are required. The chart will fail to render if no credentials are provided.

## Security Best Practices

1. **Use Kubernetes secrets**: Always use `secretName` rather than explicit credentials in values
2. **Rotate passwords**: Customer passwords should be rotated periodically
3. **Least privilege**: Each customer can only write to their own topics via PREFIXED ACLs
4. **No authorization**: While credentials provide authentication, there is no authorization enforcement at the gateway - any authenticated customer can send data with any cluster_id
5. **TLS in transit**: Use gateway mode with HTTPS for encryption in transit

## Migration from Per-Cluster to Customer Credentials

If you have existing deployments using per-cluster credentials (e.g., `redpanda-user-68e2368c`), migrate by:

1. Ensure customer credentials exist in the namespace
2. Update values file to use customer credentials:
   ```yaml
   credentials:
     secretName: "customer-pmw"  # Changed from "redpanda-user-68e2368c"
   ```
3. Upgrade the Helm release
4. Verify collector is authenticating successfully
5. Remove old per-cluster secrets (optional cleanup)
