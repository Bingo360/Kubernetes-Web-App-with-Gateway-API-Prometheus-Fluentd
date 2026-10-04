#!/usr/bin/env bash
# kubeadm init + Calico CNI + kubeconfig текущему sudo-пользователю.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Запустите скрипт с sudo." >&2
  exit 1
fi

REAL_USER="${SUDO_USER:-root}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
NODE_IP="$(hostname -I | awk '{print $1}')"
CALICO_VERSION="v3.28.0"
POD_CIDR="192.168.0.0/16"

echo "==> kubeadm init (node-ip=${NODE_IP}, pod-cidr=${POD_CIDR})"
cat >/tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.30.0
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: 10.96.0.0/12
EOF

kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs

echo "==> kubeconfig для ${REAL_USER}"
mkdir -p "${REAL_HOME}/.kube"
cp /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.kube"

echo "==> Убираем taint с control-plane (single-node)"
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo "==> Установка Calico ${CALICO_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

echo "==> Ожидание готовности узла"
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl get nodes -o wide

echo "==> Кластер готов."