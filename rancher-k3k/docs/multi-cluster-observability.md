# Multi-Cluster Observability Architecture

Plan for monitoring 15+ remote RKE2 clusters from a centralized observability stack.

## Design Principles

- **Centralized storage, distributed collection**: Each cluster runs lightweight agents that remote-write to a central cluster
- **Tenant isolation**: Each cluster is a separate tenant — metrics and logs are isolated and queryable independently
- **Horizontal scalability**: Central stack scales by adding replicas, not by scaling up
- **Cost-efficient retention**: Hot/warm/cold tiering via S3-compatible object storage
- **No Rancher dependency**: Observability stack operates independently of Rancher management

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                    Central Observability Cluster                     │
│                                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │
│  │   Grafana    │  │   Mimir     │  │    Loki     │                 │
│  │  (UI/Query)  │  │  (Metrics)  │  │   (Logs)    │                 │
│  └──────┬───────┘  └──────┬──────┘  └──────┬──────┘                 │
│         │                 │                 │                        │
│         │           ┌─────┴─────┐     ┌─────┴─────┐                 │
│         │           │   MinIO   │     │   MinIO   │                 │
│         │           │  (Blocks) │     │  (Chunks) │                 │
│         │           └───────────┘     └───────────┘                 │
│         │                                                            │
│  ┌──────┴───────┐                                                   │
│  │ Alertmanager │                                                   │
│  │  (Routing)   │                                                   │
│  └──────────────┘                                                   │
└──────────────────────────────────────────────────────────────────────┘
         ▲                    ▲                    ▲
         │                    │                    │
    remote_write         remote_write         remote_write
         │                    │                    │
┌────────┴───┐      ┌────────┴───┐      ┌────────┴───┐
│  Cluster 1 │      │  Cluster 2 │      │ Cluster N  │
│            │      │            │      │            │
│  ┌───────┐ │      │  ┌───────┐ │      │  ┌───────┐ │
│  │ Alloy │ │      │  │ Alloy │ │      │  │ Alloy │ │
│  └───────┘ │      │  └───────┘ │      │  └───────┘ │
└────────────┘      └────────────┘      └────────────┘
```

## Component Stack

### Central Cluster

| Component | Purpose | Replicas | Pool |
|-----------|---------|----------|------|
| **Grafana Mimir** | Long-term metrics storage (Prometheus-compatible) | 3 ingesters, 2 queriers, 2 distributors | general + database |
| **Grafana Loki** | Log aggregation and querying | 3 ingesters, 2 queriers, 2 distributors | general + database |
| **Grafana** | Unified dashboards and alerting UI | 2 (HA) | general |
| **Alertmanager** | Alert routing, deduplication, silencing | 3 (HA, built into Mimir) | general |
| **MinIO** | S3-compatible object storage for blocks/chunks | 4 (erasure coding) | database |
| **CNPG PostgreSQL** | Grafana database (dashboards, users, orgs) | 3 | database |

### Per-Cluster Agents

| Component | Purpose | Resources |
|-----------|---------|-----------|
| **Grafana Alloy** | Metrics collection + remote_write + log shipping | 1 DaemonSet + 1 Deployment |
| **kube-state-metrics** | Kubernetes object metrics | 1 pod |
| **node-exporter** | Node-level metrics | DaemonSet |

## Metrics Pipeline (Mimir)

### Ingestion Flow

```
Cluster N:
  kubelet metrics ──┐
  kube-state-metrics ┤
  node-exporter ─────┤──→ Alloy (scrape) ──→ remote_write ──→ Mimir Distributor
  app metrics ───────┘                                              │
                                                              Mimir Ingester
                                                                    │
                                                              MinIO (blocks)
```

### Alloy Configuration (per cluster)

```river
// Scrape Kubernetes targets
prometheus.scrape "pods" {
  targets    = discovery.kubernetes.pods.targets
  forward_to = [prometheus.remote_write.mimir.receiver]
}

prometheus.scrape "nodes" {
  targets    = discovery.kubernetes.nodes.targets
  forward_to = [prometheus.remote_write.mimir.receiver]
}

// Remote write to central Mimir
prometheus.remote_write "mimir" {
  endpoint {
    url = "https://mimir.observability.example.com/api/v1/push"

    headers = {
      "X-Scope-OrgID" = env("CLUSTER_NAME"),
    }

    basic_auth {
      username = env("MIMIR_USER")
      password = env("MIMIR_PASSWORD")
    }

    queue_config {
      max_samples_per_send = 5000
      batch_send_deadline  = "5s"
      max_shards           = 10
    }
  }
}
```

### Multi-Tenancy

Each cluster writes with a unique `X-Scope-OrgID` header. Mimir uses this for:
- **Isolation**: Cluster A cannot query Cluster B's metrics
- **Limits**: Per-tenant rate limits, series limits, retention
- **Query**: Grafana datasource per tenant, or multi-tenant queries via `|` separator

```yaml
# Mimir tenant limits (per cluster)
overrides:
  cluster-prod-01:
    ingestion_rate: 100000          # samples/sec
    max_global_series_per_user: 5000000
    compactor_blocks_retention_period: 90d
  cluster-staging-01:
    ingestion_rate: 50000
    max_global_series_per_user: 2000000
    compactor_blocks_retention_period: 30d
```

## Logging Pipeline (Loki)

### Ingestion Flow

```
Cluster N:
  container stdout/stderr ──→ Alloy (tail) ──→ Loki Distributor
  systemd journal ──────────→ Alloy (journal)        │
                                                Loki Ingester
                                                      │
                                                MinIO (chunks)
```

### Alloy Log Configuration (per cluster)

```river
// Discover and tail container logs
loki.source.kubernetes "pods" {
  targets    = discovery.kubernetes.pods.targets
  forward_to = [loki.write.central.receiver]
}

// Ship to central Loki
loki.write "central" {
  endpoint {
    url = "https://loki.observability.example.com/loki/api/v1/push"

    tenant_id = env("CLUSTER_NAME")

    basic_auth {
      username = env("LOKI_USER")
      password = env("LOKI_PASSWORD")
    }
  }
}
```

## Storage Sizing (15 Clusters)

### Assumptions

- 15 clusters, average 30 nodes each (450 nodes total)
- ~500 pods per cluster average (7,500 pods total)
- 15-second scrape interval
- 90-day metrics retention, 30-day log retention

### Metrics (Mimir)

| Metric | Value |
|--------|-------|
| Active series per cluster | ~300,000 |
| Total active series (15 clusters) | ~4,500,000 |
| Ingestion rate | ~150,000 samples/sec |
| Daily storage (compressed) | ~15 GB/day |
| 90-day retention | ~1.4 TB |
| MinIO recommendation | 4 nodes x 1 TB = 4 TB (with replication) |

### Logs (Loki)

| Metric | Value |
|--------|-------|
| Log volume per cluster | ~5 GB/day |
| Total log volume (15 clusters) | ~75 GB/day |
| 30-day retention | ~2.3 TB |
| MinIO recommendation | 4 nodes x 2 TB = 8 TB (with replication) |

### Central Cluster Sizing

| Resource | Sizing |
|----------|--------|
| Control plane nodes | 3 x 4 vCPU / 16 GB |
| General workers | 4 x 8 vCPU / 32 GB |
| Database workers | 4 x 4 vCPU / 16 GB + 2 TB disk each |
| Total vCPU | ~60 |
| Total RAM | ~240 GB |
| Total storage | ~12 TB (MinIO) + 200 GB (PVCs) |

## Network Requirements

### Bandwidth Per Cluster

| Traffic | Bandwidth |
|---------|-----------|
| Metrics remote_write | ~2-5 Mbps (compressed, batched) |
| Log shipping | ~5-15 Mbps (depends on log volume) |
| **Total per cluster** | **~10-20 Mbps** |
| **Total (15 clusters)** | **~150-300 Mbps** |

### Firewall Rules

```
Remote Cluster → Central Cluster:
  - TCP 443: Mimir push endpoint (HTTPS)
  - TCP 443: Loki push endpoint (HTTPS)

Central Cluster → Remote Clusters:
  - None required (push model, no pull)
```

### Network Resilience

- Alloy buffers metrics/logs locally during network outages (WAL)
- Mimir/Loki handle out-of-order and duplicate samples
- Recommend: dedicated ingress endpoint for observability (separate from app traffic)

## Alert Routing

```yaml
# Alertmanager routing (built into Mimir)
route:
  receiver: default
  group_by: [cluster, namespace, alertname]
  routes:
    - match:
        severity: critical
      receiver: pagerduty
      group_wait: 30s
    - match:
        severity: warning
      receiver: mattermost
      group_wait: 5m

receivers:
  - name: default
    mattermost_configs:
      - webhook_url: https://mattermost.example.com/hooks/xxx
  - name: pagerduty
    pagerduty_configs:
      - service_key: xxx
  - name: mattermost
    mattermost_configs:
      - webhook_url: https://mattermost.example.com/hooks/xxx
```

All alerts automatically include the `cluster` label, so routing can differentiate between production and staging clusters.

## Deployment Strategy

### Phase 1: Foundation (Week 1-2)
1. Deploy dedicated observability cluster (or add to existing management cluster)
2. Deploy MinIO (4-node erasure coding)
3. Deploy CNPG PostgreSQL for Grafana
4. Deploy Mimir (microservices mode)
5. Deploy Loki (microservices mode)
6. Deploy Grafana with Mimir + Loki datasources

### Phase 2: First Cluster (Week 3)
1. Deploy Alloy on one pilot cluster
2. Validate metrics flow (remote_write → Mimir → Grafana)
3. Validate log flow (Alloy → Loki → Grafana)
4. Build baseline dashboards (cluster overview, node health, pod metrics)
5. Configure initial alerts

### Phase 3: Rollout (Week 4-6)
1. Create Alloy Helm values template with per-cluster variables
2. Deploy Alloy to remaining 14 clusters via ArgoCD ApplicationSet
3. Configure per-tenant limits in Mimir/Loki
4. Build cross-cluster dashboards (fleet overview)

### Phase 4: Maturity (Week 7-8)
1. Configure alert routing (Mattermost, PagerDuty)
2. Set up recording rules for expensive queries
3. Configure log retention policies per tenant
4. Document runbooks for common alerts
5. Load test with production-like traffic

## Helm Charts

| Component | Chart | Version |
|-----------|-------|---------|
| Grafana Mimir | `grafana/mimir-distributed` | latest |
| Grafana Loki | `grafana/loki` | latest |
| Grafana | `grafana/grafana` | latest |
| Grafana Alloy | `grafana/alloy` | latest |
| MinIO | `minio/operator` | latest |
| CNPG | `cnpg/cloudnative-pg` | 0.27.1 |

## Comparison with Alternatives

| Approach | Pros | Cons |
|----------|------|------|
| **Mimir + Loki (recommended)** | Proven at scale, multi-tenant native, S3 backend, Grafana ecosystem | Operational complexity, requires object storage |
| Thanos | Prometheus-compatible, cheaper sidecar model | Weaker multi-tenancy, complex compaction |
| Victoria Metrics | Lower resource usage, simpler | Single-vendor, weaker ecosystem |
| Rancher Monitoring (per-cluster) | Simple, built-in | No cross-cluster view, per-cluster retention cost |
| Datadog / New Relic (SaaS) | Zero ops | Cost at 15 clusters, data sovereignty |

## Key Decisions to Make

1. **Dedicated cluster vs. co-located**: Observability on its own cluster, or on the management cluster with Rancher?
   - Recommendation: Dedicated cluster for isolation and independent scaling
2. **Object storage**: Self-hosted MinIO or cloud S3?
   - Recommendation: MinIO on database pool (consistent with existing pattern)
3. **Log retention**: How long to keep logs? (cost vs. compliance)
   - Recommendation: 30 days hot, 90 days cold (S3 lifecycle)
4. **Alert channels**: Mattermost only, or also PagerDuty/email for critical?
5. **Dashboard strategy**: Per-cluster dashboards, fleet-wide, or both?
   - Recommendation: Both — fleet overview + drill-down per cluster
