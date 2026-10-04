#!/usr/bin/env bash
set -euo pipefail

FULL=false
[[ "${1:-}" == "-f" || "${1:-}" == "--full" ]] && FULL=true

log() { echo -e "\n\033[1;33m[destroy]\033[0m $*"; }

log "Удаление Fluentd"
kubectl delete -f manifests/logging/fluentd.yaml --ignore-not-found

log "Удаление ServiceMonitor"
kubectl delete -f manifests/monitoring/servicemonitor.yaml --ignore-not-found

log "Удаление kube-prometheus-stack"
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true
kubectl delete ns monitoring --ignore-not-found

log "Удаление Gateway API ресурсов"
kubectl delete -f manifests/gateway/ --ignore-not-found

log "Удаление приложения"
kubectl delete -f manifests/app/nginx.yaml --ignore-not-found

log "Удаление Envoy Gateway"
helm uninstall eg -n envoy-gateway-system 2>/dev/null || true
kubectl delete ns envoy-gateway-system --ignore-not-found

log "Удаление Gateway API CRDs"
kubectl delete -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml" --ignore-not-found || true

if $FULL; then
  log "Полное удаление кластера kubeadm"
  sudo kubeadm reset -f
  sudo rm -rf /etc/cni/net.d /var/lib/etcd "$HOME/.kube"
  sudo systemctl restart containerd
fi

log "Готово."