# k3d-kserve-observability-setup
Bash script to bootstrap a local Kubernetes-based ML serving and observability platform using k3d, KServe, and Grafana with metrics, logs, and traces support.

## 🚀 Components

### Infrastructure
- Docker
- k3d (K3s Kubernetes cluster)

### Serving Layer
- Knative (serverless platform)
- KServe (model serving)

### Observability
- VictoriaMetrics (metrics)
- VictoriaLogs (logs)
- Jaeger (traces)
- OpenTelemetry Collector
- Fluent Bit (log collection)
- vmagent (metrics scraping)

### Visualization
- Grafana (pre-configured dashboards)
- 
## ⚡ Quick Start

```bash
chmod +x setup.sh
./setup.sh
