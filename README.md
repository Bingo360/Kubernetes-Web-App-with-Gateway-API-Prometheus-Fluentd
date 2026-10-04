# Kubernetes-Web-App-with-Gateway-API-Prometheus-Fluentd
## 1. Архитектура

```text
                    ┌──────────────────────────────┐
   HTTP :30080      │        Ubuntu 24.04          │
  ────────────────► │  kubeadm single-node k8s     │
                    │  Calico CNI                  │
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │   Envoy Gateway (Gateway API)│
                    │   GatewayClass → Gateway     │
                    │   HTTPRoute → nginx Service  │
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │  Deployment: nginx           │
                    │   ├─ nginx:1.27 (Hello World)│
                    │   └─ nginx-exporter :9113    │
                    └──────────────┬───────────────┘
                                   │ scrape
                    ┌──────────────▼───────────────┐
                    │  kube-prometheus-stack       │
                    │   Prometheus + Grafana       │
                    └──────────────────────────────┘

  Fluentd DaemonSet ──tail──► /var/log/containers/*nginx*.log ──► stdout
```

- **Ingress**: Envoy Gateway → `GatewayClass/eg`, `Gateway/web-gateway`, `HTTPRoute/nginx-route`
- **App**: `nginx:1.27.0` + `nginx/nginx-prometheus-exporter:1.2.0` (sidecar)
- **Monitoring**: `kube-prometheus-stack` (Prometheus Operator, Grafana)
- **Logging**: Fluentd DaemonSet читает `/var/log/containers/*nginx*.log`

## 2. Использованные технологии и версии

| Компонент              | Версия                              |
|------------------------|-------------------------------------|
| Операционная система   | Ubuntu 24.04 LTS                    |
| Kubernetes             | v1.30 (kubeadm, single-node)        |
| Container runtime      | containerd 1.7.x                    |
| CNI                    | Calico v3.28.0                      |
| Gateway API CRDs       | v1.1.0                              |
| Envoy Gateway          | v1.0.0 (Helm chart)                 |
| Приложение             | nginx:1.27.0                        |
| Exporter               | nginx/nginx-prometheus-exporter:1.2.0 |
| Мониторинг             | kube-prometheus-stack 61.3.0        |
| Логирование            | Fluentd (fluentd-kubernetes-daemonset:v1.17-debian-1.1) |
| Helm                   | ≥ 3.14                              |
| kubectl                | ≥ 1.30                              |

## 3. Требования к среде

- **Ubuntu 24.04 LTS** (тестировалось), x86_64.
- Минимум: **2 vCPU, 4 GB RAM, 20 GB диска** (рекомендуется 4 vCPU / 8 GB).
- Root-доступ или sudo.
- Открытые порты: 6443 (API), 30000–32767 (NodePort), доступ в интернет для pull образов.
- Установлены: `curl`, `git`, `make`.

## 4. Пошаговое развёртывание

### 4.1. Клонировать репозиторий

```bash
git clone ... hackathon
cd hackathon
```

### 4.2. Установить кластер (kubeadm, containerd, Calico)

```bash
sudo ./scripts/01-install-prereqs.sh   # containerd, kubeadm, kubelet, kubectl
sudo ./scripts/02-init-cluster.sh      # kubeadm init + Calico + kubeconfig
```

Скрипт `02-init-cluster.sh`:
- инициализирует кластер через `kubeadm init`;
- снимает taint с control-plane (single-node);
- ставит Calico как CNI;
- копирует kubeconfig в `$HOME/.kube/config` пользователя, под которым запускался `sudo`.

> Если `kubectl get nodes` показывает `NotReady` — подождите 30–60 секунд, пока
> Calico поднимется.

### 4.3. Развернуть всё остальное одной командой

```bash
make deploy
```

`make deploy` вызовет `./deploy.sh`, который идемпотентно (можно запускать
повторно) устанавливает:
1. Gateway API CRDs v1.1.0
2. Envoy Gateway v1.0.0 (Helm, namespace `envoy-gateway-system`)
3. Манифесты приложения (namespace `default`)
4. GatewayClass / Gateway / HTTPRoute
5. kube-prometheus-stack (namespace `monitoring`)
6. ServiceMonitor для nginx
7. Fluentd DaemonSet (namespace `logging`)

### 4.4. Удаление

```bash
make destroy      # удаляет все компоненты (кластер остаётся)
```

Полное удаление кластера — отдельной командой (см. `destroy.sh -f`).

## 5. Проверка доступности приложения через Gateway API

Envoy Gateway создаёт сервис с типом `LoadBalancer`. На single-node kubeadm он
останется в статусе `Pending`, но получит внешний порт (NodePort) — используем его.

```bash
# Найти сервис Envoy Gateway
kubectl get svc -n envoy-gateway-system

# Узнать NodePort (обычно в диапазоне 30000-32767)
NODEPORT=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=web-gateway \
  -o jsonpath='{.items[0].spec.ports[0].nodePort}')
echo "NodePort=$NODEPORT"

# Проверить ответ
curl -s http://localhost:${NODEPORT}/
# Ожидаемый вывод: Hello World!
```

Альтернативный способ (если NodePort недоступен снаружи):

```bash
kubectl port-forward -n envoy-gateway-system \
  svc/$(kubectl get svc -n envoy-gateway-system -o name | head -1 | cut -d/ -f2) 8080:80 &
curl -s http://localhost:8080/
```

## 6. Проверка мониторинга (Prometheus)

### 6.1. Доступ к UI Prometheus

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

Открыть в браузере: <http://localhost:9090>

### 6.2. Проверить target

В UI: **Status → Targets** → найти `serviceMonitor/monitoring/nginx/0` в статусе **UP**.

### 6.3. PromQL запросы

Выполнить в UI (раздел **Graph**):

```promql
nginx_up
nginx_http_requests_total
nginx_connections_active
up{job="nginx"}
```

`nginx_up == 1` подтверждает, что exporter доступен, а через него — сам nginx.

### 6.4. Проверка метрик через CLI

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query?query=nginx_up' | jq .
```

**Собираемые метрики:**
- `nginx_up` — доступность nginx (1/0)
- `nginx_http_requests_total` — количество HTTP-запросов
- `nginx_connections_active` — активные соединения
- `up{job="nginx"}` — доступность самого exporter

## 7. Проверка логирования (Fluentd)

Fluentd запущен как DaemonSet в namespace `logging`, читает
`/var/log/containers/*nginx*.log` и выводит их в собственный stdout.

### 7.1. Сгенерировать трафик

```bash
NODEPORT=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=web-gateway \
  -o jsonpath='{.items[0].spec.ports[0].nodePort}')
for i in 1 2 3; do curl -s http://localhost:${NODEPORT}/; done
```

### 7.2. Убедиться, что логи появились у Fluentd

```bash
kubectl logs -n logging daemonset/fluentd --tail=50 | grep -i "GET /"
```

Ожидаемая запись (JSON-строка access-лога nginx):

```json
{"log":"10.0.0.1 - - [..] \"GET / HTTP/1.1\" 200 13 \"-\" \"curl/8.x\"\n","stream":"stdout",...}
```

### 7.3. Собираемые логи

- `access.log` nginx — метод, путь, статус, user-agent
- `error.log` nginx — ошибки (если возникнут)

Хранилище: **stdout Fluentd** (простой и воспроизводимый вариант). Для
production можно добавить output в Elasticsearch/Loki — см. раздел
"Дополнительные возможности".

## 8. Дополнительные возможности

- **Gateway API**: используется `HTTPRoute` с `PathPrefix`. Легко расширяется
  до нескольких маршрутов, hostname-роутинга, traffic splitting.
- **kube-prometheus-stack**: включает Grafana, Alertmanager, node-exporter,
  kube-state-metrics — мониторинг покрывает и инфраструктуру.
- **Sidecar-exporter**: приложение и exporter в одном Pod — упрощает
  сетевую связность (`localhost:80/stub_status`).
- **Идемпотентность**: `deploy.sh` использует `helm upgrade --install` и
  `kubectl apply`, повторный запуск безопасен.
- **Без секретов в репозитории**: все секреты генерируются Helm'ом.

## 9. Известные ограничения

- Single-node kubeadm: `control-plane` taint снят; для HA нужны ещё ноды.
- Gateway публикуется через NodePort (нет внешнего LoadBalancer на bare-metal).
- TLS не настроен (можно добавить cert-manager + listener HTTPS).
- Логи Fluentd пишутся в stdout (без централизованного хранилища).
- Образы тянутся из публичных реестров (Docker Hub, Quay, GHCR).

## 10. Команды быстрого старта

```bash
git clone <URL> && cd k8s-hackathon
sudo ./scripts/01-install-prereqs.sh
sudo ./scripts/02-init-cluster.sh
make deploy

# Проверки
NODEPORT=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=web-gateway \
  -o jsonpath='{.items[0].spec.ports[0].nodePort}')
curl -s http://localhost:${NODEPORT}/                # → Hello World!
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
kubectl logs -n logging daemonset/fluentd --tail=20
```
