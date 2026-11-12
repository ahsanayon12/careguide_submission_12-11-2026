# Convenience targets. Every target is a thin wrapper - the README shows the raw commands too.
SHELL := /bin/bash
VERSION ?= $(shell cat VERSION)
IMAGE   ?= careguide-api
COMPOSE := docker compose -f docker-compose.yml -f docker-compose.monitoring.yml
KIND_CLUSTER ?= careguide

.PHONY: help install lint test build up down monitoring monitoring-down logs health \
        kind-up kind-load k8s-deploy k8s-rollout-demo k8s-down tf-fmt

help: ## Show targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-18s %s\n",$$1,$$2}'

install: ## Install dev dependencies into the active Python env
	pip install -r requirements-dev.txt

lint: ## Ruff + shellcheck + hadolint (if installed)
	ruff check . && ruff format --check .
	shellcheck --shell=bash scripts/*.sh terraform/app/templates/*.sh terraform/app/templates/*.tftpl
	@command -v hadolint >/dev/null && hadolint Dockerfile || echo "hadolint not installed - skipped (CI runs it)"

test: ## Unit tests with coverage
	python -m pytest --cov=app --cov-report=term-missing

build: ## Build the runtime image
	docker build --target runtime --build-arg APP_VERSION=$(VERSION) -t $(IMAGE):$(VERSION) .
	@docker image ls $(IMAGE):$(VERSION) --format 'Image size: {{.Size}}'

up: ## Run the app only (http://localhost:8080)
	docker compose up -d --build

down: ## Stop the app
	docker compose down

monitoring: ## Run app + full observability stack (Grafana http://localhost:3000)
	@test -f .env || (cp .env.example .env && echo "Created .env from .env.example - change GRAFANA_ADMIN_PASSWORD")
	$(COMPOSE) up -d --build

monitoring-down: ## Stop everything (keeps volumes)
	$(COMPOSE) down

logs: ## Tail app logs
	docker compose logs -f app

health: ## Run the health script once
	./scripts/system_health.sh --log-file ./health_log.txt

kind-up: ## Create kind cluster + ingress-nginx + metrics-server
	kind create cluster --name $(KIND_CLUSTER) --config k8s/kind-cluster.yaml
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.3/deploy/static/provider/kind/deploy.yaml
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.0/components.yaml
	kubectl -n kube-system patch deployment metrics-server --type=json \
	  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
	kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s

kind-load: build ## Build and load the image into kind
	kind load docker-image $(IMAGE):$(VERSION) --name $(KIND_CLUSTER)

k8s-deploy: ## Create secret (if missing) and apply manifests
	kubectl apply -f k8s/namespace.yaml
	kubectl -n careguide get secret careguide-secrets >/dev/null 2>&1 || \
	  kubectl -n careguide create secret generic careguide-secrets --from-literal=API_TOKEN="$$(openssl rand -hex 32)"
	kubectl apply -k k8s
	kubectl -n careguide rollout status deploy/careguide-api --timeout=120s

k8s-rollout-demo: ## Zero-downtime rolling update to 1.1.0 + rollout undo (with traffic)
	./scripts/k8s_rollout_demo.sh

k8s-down: ## Delete the kind cluster
	kind delete cluster --name $(KIND_CLUSTER)

tf-fmt: ## Format Terraform
	terraform fmt -recursive terraform
