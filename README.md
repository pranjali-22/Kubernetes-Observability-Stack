#  Kubernetes Observability Stack

A production-grade observability stack for Kubernetes using the **RED Method**
(Rate · Errors · Duration). Deploys a Node.js app instrumented with `prom-client`,
Prometheus + Grafana via Helm, alert rules, and Loki for centralized logging.

---

##  Project Structure

```
k8s-observability/
├── app/
│   ├── index.js              # Node.js app — prom-client instrumented
│   ├── package.json
│   └── Dockerfile
├── k8s/
│   ├── app/
│   │   └── deployment.yaml   # Deployment, Service, ServiceMonitor, HPA
│   ├── grafana/
│   │   ├── dashboard.json    # RED Method Grafana dashboard
│   │   └── dashboard-configmap.yaml
│   └── loki/
│       └── datasource.yaml   # Loki datasource for Grafana
├── helm-values/
│   ├── prometheus.yaml       # kube-prometheus-stack values + alert rules
│   └── loki.yaml             # Loki + Promtail values
├── scripts/
│   ├── deploy.sh             # Full one-command deployment
│   └── load-test.sh          # Traffic generator
└── kustomization.yaml
```

---

##  Quick Start

### Prerequisites

| Tool | Version |
|------|---------|
| kubectl | ≥ 1.28 |
| helm | ≥ 3.12 |
| docker | ≥ 24 |
| kind / minikube | any (for local) |

### 1. One-command deploy

```bash
chmod +x scripts/deploy.sh scripts/load-test.sh
./scripts/deploy.sh all
```

Or step by step:

```bash
./scripts/deploy.sh prereqs     # Check tools & add Helm repos
./scripts/deploy.sh build       # Build Docker image
./scripts/deploy.sh prometheus  # Install kube-prometheus-stack
./scripts/deploy.sh dashboard   # Apply Grafana dashboard
./scripts/deploy.sh loki        # Install Loki + Promtail (bonus)
./scripts/deploy.sh app         # Deploy Node.js app
```

### 2. Port-forward

```bash
# Grafana
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
# → http://localhost:3000  (admin / admin123)

# Prometheus
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring
# → http://localhost:9090

# Alertmanager
kubectl port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093 -n monitoring

# App
kubectl port-forward svc/observability-app 8080:80 -n observability-demo
```

### 3. Generate traffic

```bash
BASE_URL=http://localhost:8080 DURATION=120 RPS=30 ./scripts/load-test.sh
```

---

##  Metrics Exposed

### RED Method

| Metric | Type | Description |
|--------|------|-------------|
| `http_requests_total` | Counter | Request rate by method, route, status |
| `http_request_errors_total` | Counter | 4xx + 5xx errors |
| `http_request_duration_seconds` | Histogram | Latency (p50/p95/p99) |
| `http_requests_in_flight` | Gauge | Concurrent requests |

### Business Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `orders_created_total` | Counter | Orders by status (success/failed) |
| `active_users` | Gauge | Simulated active user count |
| `db_query_duration_seconds` | Histogram | Query latency by operation & table |

### Default Node.js Metrics (via prom-client)

- `nodejs_app_nodejs_heap_size_used_bytes`
- `nodejs_app_nodejs_eventloop_lag_seconds`
- `nodejs_app_nodejs_gc_duration_seconds`
- `nodejs_app_process_cpu_seconds_total`
- … and more

---

##  Alert Rules

All rules live in `helm-values/prometheus.yaml` → `additionalPrometheusRulesMap`.

### RED Method Alerts

| Alert | Condition | Severity |
|-------|-----------|----------|
| `HighErrorRate` | Error rate > 5% for 2m |  critical |
| `High5xxErrorRate` | 5xx rate > 1% for 2m |  warning |
| `HighP99Latency` | p99 > 2s for 5m | warning |
| `HighP95Latency` | p95 > 1s for 5m |  warning |
| `LowRequestRate` | < 0.1 req/s for 5m |  warning |

### Infrastructure Alerts

| Alert | Condition | Severity |
|-------|-----------|----------|
| `PodNotReady` | Pod not ready > 5m |  critical |
| `PodCrashLooping` | > 3 restarts in 15m | critical |
| `HighMemoryUsage` | > 85% memory limit |  warning |
| `HighCPUUsage` | > 80% CPU limit |  warning |

### Database Alerts

| Alert | Condition | Severity |
|-------|-----------|----------|
| `SlowDBQueries` | p95 query > 500ms |  warning |

---

## Grafana Dashboard

Import `k8s/grafana/dashboard.json` manually, or it's auto-provisioned via
the `grafana-dashboards` ConfigMap.

Dashboard sections:
1. **RED Method Overview** — stat panels for rate, error %, p99, p95, in-flight, active users
2. **Request Rate & Traffic** — by route and by status code
3. **Error Rate** — overall + per-route with 5% alert threshold line
4. **Latency Distribution** — p50/p95/p99 over time + per-route breakdown
5. **Resource Usage** — Node.js heap, event loop lag
6. **DB Query Performance** — p95 duration and throughput by operation

---

##  Bonus: Centralized Logging with Loki

Loki + Promtail is installed by `./scripts/deploy.sh loki`.

Promtail is configured to:
- Tail all pod logs in the cluster
- Parse JSON logs from the Node.js app (level, method, path, status, duration_ms)
- Drop noisy health-check and metrics-scrape log lines

**To query logs in Grafana:**
1. Go to Explore → select **Loki** datasource
2. Use LogQL:
   ```logql
   {namespace="observability-demo"} | json | status >= 500
   {namespace="observability-demo"} | json | duration_ms > 1000
   {namespace="observability-demo", level="error"}
   ```

---

## Customisation

### Change scrape interval
Edit `prometheus.prometheusSpec.scrapeInterval` in `helm-values/prometheus.yaml`.

### Add Slack alerts
Set `slack_api_url` and `channel` in `alertmanager.config` in `helm-values/prometheus.yaml`.

### Scale replicas
Edit `spec.replicas` in `k8s/app/deployment.yaml`, or let the HPA handle it automatically.

### Add a new metric
```js
// In app/index.js
const myCounter = new client.Counter({
  name: 'my_custom_total',
  help: 'Description',
  labelNames: ['label1'],
  registers: [register],
});

myCounter.inc({ label1: 'value' });
```

---

##  Teardown

```bash
# Remove the app
kubectl delete namespace observability-demo

# Remove monitoring stack
helm uninstall prometheus -n monitoring
helm uninstall loki -n monitoring
kubectl delete namespace monitoring
```
