#!/usr/bin/env bash
# =============================================================================
# deploy.sh  —  Full Kubernetes Observability Stack Deployment
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
MONITORING_NS="monitoring"
APP_NS="observability-demo"
APP_IMAGE="observability-app:latest"
REGISTRY="${REGISTRY:-""}"  # Set to your registry, e.g. "ghcr.io/yourorg"

# ── Prerequisites check ───────────────────────────────────────────────────────
check_prerequisites() {
  info "Checking prerequisites..."
  for cmd in kubectl helm docker; do
    if ! command -v "$cmd" &>/dev/null; then
      error "$cmd is not installed. Please install it first."
    fi
  done

  if ! kubectl cluster-info &>/dev/null; then
    error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
  fi

  # Helm repos
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
  helm repo update
  success "Prerequisites OK"
}

# ── Build & push app image ────────────────────────────────────────────────────
build_app() {
  info "Building Node.js app Docker image..."
  docker build -t "$APP_IMAGE" ./app

  if [[ -n "$REGISTRY" ]]; then
    info "Pushing to registry: $REGISTRY"
    docker tag "$APP_IMAGE" "$REGISTRY/$APP_IMAGE"
    docker push "$REGISTRY/$APP_IMAGE"
  else
    # Load into kind/minikube if using local cluster
    if command -v kind &>/dev/null && kind get clusters &>/dev/null; then
      info "Loading image into kind cluster..."
      kind load docker-image "$APP_IMAGE"
    elif command -v minikube &>/dev/null && minikube status &>/dev/null; then
      info "Loading image into minikube..."
      minikube image load "$APP_IMAGE"
    else
      warn "No remote registry set and no local cluster tool (kind/minikube) detected."
      warn "Set REGISTRY env var or manually load the image."
    fi
  fi
  success "App image ready: $APP_IMAGE"
}

# ── Monitoring namespace & Prometheus stack ───────────────────────────────────
install_prometheus() {
  info "Installing kube-prometheus-stack..."
  kubectl create namespace "$MONITORING_NS" --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace "$MONITORING_NS" \
    --values helm-values/prometheus.yaml \
    --wait \
    --timeout 10m

  success "Prometheus + Grafana installed in namespace: $MONITORING_NS"
}

# ── Grafana dashboard ─────────────────────────────────────────────────────────
apply_grafana_dashboard() {
  info "Applying Grafana dashboard ConfigMap..."

  # Inline the JSON into the ConfigMap on the fly
  DASHBOARD_JSON=$(cat k8s/grafana/dashboard.json)

  kubectl create configmap grafana-dashboards \
    --namespace "$MONITORING_NS" \
    --from-literal="app-red-metrics.json=$DASHBOARD_JSON" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Label it so Grafana sidecar picks it up
  kubectl label configmap grafana-dashboards \
    --namespace "$MONITORING_NS" \
    grafana_dashboard=1 --overwrite

  success "Dashboard ConfigMap applied"
}

# ── Loki stack (bonus) ────────────────────────────────────────────────────────
install_loki() {
  info "Installing Loki + Promtail for centralized logging..."

  helm upgrade --install loki grafana/loki-stack \
    --namespace "$MONITORING_NS" \
    --values helm-values/loki.yaml \
    --wait \
    --timeout 5m

  # Loki datasource ConfigMap
  kubectl apply -f k8s/loki/datasource.yaml

  success "Loki stack installed"
}

# ── Application deployment ────────────────────────────────────────────────────
deploy_app() {
  info "Deploying Node.js application..."
  kubectl create namespace "$APP_NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f k8s/app/deployment.yaml

  info "Waiting for deployment to be ready..."
  kubectl rollout status deployment/observability-app \
    --namespace "$APP_NS" \
    --timeout 3m

  success "Application deployed to namespace: $APP_NS"
}

# ── Print access info ─────────────────────────────────────────────────────────
print_access_info() {
  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✅  Deployment Complete!${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
  echo ""
  echo "  To access Grafana:"
  echo "    kubectl port-forward svc/prometheus-grafana 3000:80 -n $MONITORING_NS"
  echo "    Open: http://localhost:3000  (admin / admin123)"
  echo ""
  echo "  To access Prometheus:"
  echo "    kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n $MONITORING_NS"
  echo "    Open: http://localhost:9090"
  echo ""
  echo "  To access Alertmanager:"
  echo "    kubectl port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093 -n $MONITORING_NS"
  echo "    Open: http://localhost:9093"
  echo ""
  echo "  To access the App:"
  echo "    kubectl port-forward svc/observability-app 8080:80 -n $APP_NS"
  echo "    Open: http://localhost:8080"
  echo ""
  echo "  To generate load:"
  echo "    ./scripts/load-test.sh"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BLUE}"
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║  K8s Observability Stack Installer       ║"
  echo "  ║  Prometheus · Grafana · Loki · RED       ║"
  echo "  ╚══════════════════════════════════════════╝"
  echo -e "${NC}"

  check_prerequisites
  build_app
  install_prometheus
  apply_grafana_dashboard
  install_loki
  deploy_app
  print_access_info
}

# Allow running individual steps: ./deploy.sh prometheus | loki | app | dashboard
case "${1:-all}" in
  all)          main ;;
  prereqs)      check_prerequisites ;;
  build)        build_app ;;
  prometheus)   install_prometheus ;;
  dashboard)    apply_grafana_dashboard ;;
  loki)         install_loki ;;
  app)          deploy_app ;;
  info)         print_access_info ;;
  *)            error "Unknown step: $1. Use: all | prereqs | build | prometheus | dashboard | loki | app | info" ;;
esac
