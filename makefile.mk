SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help deploy destroy clean logs metrics

help: ## Показать справку
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "};{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

deploy: ## Развернуть всё решение (идемпотентно)
	./deploy.sh

destroy: ## Удалить компоненты решения (кластер остаётся)
	./destroy.sh

clean: ## Полностью удалить кластер kubeadm
	./destroy.sh -f

logs: ## Показать последние логи Fluentd
	kubectl logs -n logging daemonset/fluentd --tail=50

metrics: ## Показать nginx_up из Prometheus
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 & \
		sleep 2; \
		curl -s 'http://localhost:9090/api/v1/query?query=nginx_up'; \
		kill %1