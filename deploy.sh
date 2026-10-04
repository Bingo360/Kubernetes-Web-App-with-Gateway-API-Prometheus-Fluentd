#!/usr/bin/env bash
# Идемпотентное развёртывание всего стека поверх готового кластера kubeadm.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

GATEWAY_API_VERSION="v1.1.0"
ENVOY_GATEWAY_VERSION="v1.0.0"
PROM_STACK_VERSION="61.3.0"

log() { echo -e "\n\033[1;34m[deploy]\033[0m $*"; }

log "1/7 Установка Gateway API CRDs ${GATEWAY_API_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

log "2/7 Установка Envoy Gateway ${ENVOY_GATEWAY_VERSION}"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  --namespace envoy-gateway-system --create-namespace \
  --values helm/envoy-gateway-values.yaml \
  --wait --timeout 5m

log "3/7 Ожидание готовности Envoy Gateway"
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s

log "4/7 Развёртывание приложения nginx"
kubectl apply -f manifests/app/nginx.yaml
kubectl rollout status deploy/nginx --timeout=120s

log "5/7 Развёртывание Gateway API ресурсов"
kubectl apply -f manifests/gateway/gatewayclass.yaml
kubectl apply -f manifests/gateway/gateway.yaml
kubectl apply -f manifests/gateway/httproute.yaml

log "6/7 Установка kube-prometheus-stack ${PROM_STACK_VERSION}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "${PROM_STACK_VERSION}" \
  --namespace monitoring --create-namespace \
  --values helm/prometheus-values.yaml \
  --wait --timeout 10m

kubectl apply -f manifests/monitoring/servicemonitor.yaml

log "7/7 Развёртывание Fluentd"
kubectl apply -f manifests/logging/fluentd.yaml
kubectl -n logging rollout status daemonset/fluentd --timeout=120s

log "Готово. Ждём появления NodePort у Gateway..."
for i in {1..30}; do
  NODEPORT=$(kubectl get svc -n envoy-gateway-system \
    -l gateway.envoyproxy.io/owning-gateway-name=web-gateway \
    -o jsonpath='{.items[0].spec.ports[0].nodePort}' 2>/dev/null || true)
  [[ -n "${NODEPORT}" ]] && break
  sleep 2
done

echo
echo "======================================================="
echo " Приложение доступно:  http://localhost:${NODEPORT}/"
echo " Проверка:             curl -s http://localhost:${NODEPORT}/"
echo " Prometheus UI:        kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo " Логи Fluentd:         make logs"
echo "======================================================="