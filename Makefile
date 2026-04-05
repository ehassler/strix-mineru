# ── MinerU ROCm Service ──────────────────────────────────────────────────────
#
# Usage:
#   make build              Build the Docker image
#   make download-models    Download MinerU models into persistent volume
#   make up                 Start the API service (background)
#   make down               Stop the API service
#   make restart            Restart the API service
#   make logs               Tail service logs
#   make status             Show container status and health
#   make shell              Open a shell in a running container
#   make test               Quick smoke test against the API
#   make clean              Stop service and remove container (keeps volumes)
#   make clean-all          Stop service, remove container AND model volume

IMAGE_NAME   ?= mineru-rocm
IMAGE_TAG    ?= latest
IMAGE        := $(IMAGE_NAME):$(IMAGE_TAG)
COMPOSE      := docker compose
SERVICE      := mineru-api

# Import .env so all config lives in one place.
# docker-compose reads .env automatically; this makes make do the same.
-include .env
export

.PHONY: build download-models up down restart logs status shell diagnose test clean clean-all help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Build ────────────────────────────────────────────────────────────────────

build: ## Build the Docker image
	$(COMPOSE) build $(SERVICE)

# ── Model Management ────────────────────────────────────────────────────────

download-models: ## Download MinerU models into persistent volume
	@mkdir -p $(MINERU_MODELS) $(MINERU_WORKSPACE) $(MINERU_OUTPUT)
	$(COMPOSE) run --rm --entrypoint mineru-models-download $(SERVICE)
	@echo ""
	@echo "Models downloaded.  Run 'make up' to start the service."

# ── Service Lifecycle ────────────────────────────────────────────────────────

up: ## Start the API service (detached)
	@mkdir -p $(MINERU_MODELS) $(MINERU_WORKSPACE) $(MINERU_OUTPUT)
	$(COMPOSE) up -d $(SERVICE)
	@echo ""
	@echo "MinerU API starting on http://localhost:$(MINERU_PORT)"
	@echo "  API docs:  http://localhost:$(MINERU_PORT)/docs"
	@echo "  Health:    http://localhost:$(MINERU_PORT)/health"
	@echo ""
	@echo "Run 'make logs' to watch startup progress."

down: ## Stop the API service
	$(COMPOSE) down

restart: ## Restart the API service
	$(COMPOSE) restart $(SERVICE)

# ── Observability ────────────────────────────────────────────────────────────

logs: ## Tail service logs (Ctrl-C to stop)
	$(COMPOSE) logs -f $(SERVICE)

status: ## Show container status and health
	@docker inspect --format '{{.Name}}  state={{.State.Status}}  health={{.State.Health.Status}}' mineru 2>/dev/null \
		|| echo "Container 'mineru' is not running."

# ── Development / Debugging ──────────────────────────────────────────────────

shell: ## Open a bash shell in the running container
	docker exec -it mineru bash

diagnose: ## Run GPU/ROCm/MinerU diagnostic in the running container
	docker exec -it mineru python /opt/mineru/diagnose.py

test: ## Smoke test: hit the health endpoint
	@curl -sf http://localhost:$(MINERU_PORT)/health \
		&& echo " ✓ MinerU API is healthy" \
		|| echo " ✗ MinerU API is not responding (is it running?)"

# ── Cleanup ──────────────────────────────────────────────────────────────────

clean: ## Stop service and remove container (keeps model volume)
	$(COMPOSE) down --remove-orphans

clean-all: ## Stop service, remove container AND local model cache
	$(COMPOSE) down --remove-orphans
	rm -rf $(MINERU_MODELS)
	@echo "Model cache removed.  Run 'make download-models' before next 'make up'."