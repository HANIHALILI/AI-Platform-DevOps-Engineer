# Agent service — local kind cluster, registry, image, Helm release.

.DEFAULT_GOAL := help
SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

CLUSTER_NAME  ?= ai-platform-cluster
REGISTRY_NAME ?= kind-registry
REGISTRY_PORT ?= 5001
REGISTRY_IMAGE ?= registry:3@sha256:1be55279f18a2fe1a74edf2664cac61c1bea305b7b4642dab412e7affdcb3e33
KIND_CONFIG   ?= k8s/kind-config.yaml
# pinned to a digest so the node image always matches KIND_VERSION
NODE_IMAGE    ?= kindest/node:v1.34.8@sha256:02722c2dedddcfc00febf5d27fbeb9b7b2c14294c82109ff4a85d89ac9ba3256
IMAGE         ?= localhost:$(REGISTRY_PORT)/agent
IMAGE_TAG     ?= dev
RELEASE       ?= agent
NAMESPACE     ?= default
MAX_IMAGE_MB  ?= 250

KIND_VERSION    ?= v0.32.0
KUBECTL_VERSION ?= v1.34.8
HELM_VERSION    ?= v3.21.4
ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
BIN_DIR ?= $(HOME)/.local/bin
export PATH := $(BIN_DIR):$(PATH)

.PHONY: help deps registry cluster up build push deploy all smoke down clean

help:
	@echo "make deps    install docker/kind/kubectl/helm if missing"
	@echo "make up      deps + registry + 3-node cluster"
	@echo "make build   build $(IMAGE):$(IMAGE_TAG)"
	@echo "make push    push it to the local registry"
	@echo "make deploy  helm upgrade --install"
	@echo "make all     up + build + push + deploy"
	@echo "make smoke   end-to-end checks"
	@echo "make down    delete the cluster"
	@echo "make clean   delete the cluster and the registry"

deps:
	@command -v docker >/dev/null || { sudo apt-get update -y; sudo apt-get install -y docker.io docker-buildx; }
	sudo systemctl enable --now docker >/dev/null
	id -nG "$$USER" | tr ' ' '\n' | grep -qx docker || {
	  sudo usermod -aG docker "$$USER"
	  exec sg docker -c "$(MAKE) deps"
	}
	mkdir -p $(BIN_DIR)
	command -v kind >/dev/null || {
	  curl -fsSL -o $(BIN_DIR)/kind "https://kind.sigs.k8s.io/dl/$(KIND_VERSION)/kind-linux-$(ARCH)"
	  chmod +x $(BIN_DIR)/kind
	}
	command -v kubectl >/dev/null || {
	  curl -fsSL -o $(BIN_DIR)/kubectl "https://dl.k8s.io/release/$(KUBECTL_VERSION)/bin/linux/$(ARCH)/kubectl"
	  chmod +x $(BIN_DIR)/kubectl
	}
	command -v helm >/dev/null || {
	  curl -fsSL "https://get.helm.sh/helm-$(HELM_VERSION)-linux-$(ARCH).tar.gz" | tar -xz -C /tmp
	  install -m 0755 /tmp/linux-$(ARCH)/helm $(BIN_DIR)/helm
	}
	test -f app/uv.lock || { echo "app/uv.lock missing — run: uv lock --directory app"; exit 1; }
	echo "deps ok"

registry:
	@if [ "$$(docker inspect -f '{{.State.Running}}' $(REGISTRY_NAME) 2>/dev/null)" = true ]; then
	  :
	elif docker inspect $(REGISTRY_NAME) >/dev/null 2>&1; then
	  docker start $(REGISTRY_NAME) >/dev/null
	else
	  docker run -d --restart=always --name $(REGISTRY_NAME) --network bridge \
	    -p 127.0.0.1:$(REGISTRY_PORT):5000 $(REGISTRY_IMAGE) >/dev/null
	fi
	for i in $$(seq 10); do
	  curl -fsS http://localhost:$(REGISTRY_PORT)/v2/_catalog >/dev/null 2>&1 && exit 0
	  sleep 2
	done
	echo "registry did not respond on :$(REGISTRY_PORT)" >&2; exit 1

# the registry can only join the "kind" docker network after the cluster
# creates it, and containerd needs the mirror written on every node.
cluster:
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER_NAME) || \
	  kind create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG) --image $(NODE_IMAGE) --wait 180s
	kubectl config use-context kind-$(CLUSTER_NAME) >/dev/null
	for node in $$(kind get nodes --name $(CLUSTER_NAME)); do
	  docker exec "$$node" mkdir -p /etc/containerd/certs.d/localhost:$(REGISTRY_PORT)
	  echo '[host."http://$(REGISTRY_NAME):5000"]' | docker exec -i "$$node" cp /dev/stdin /etc/containerd/certs.d/localhost:$(REGISTRY_PORT)/hosts.toml
	done
	[ "$$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' $(REGISTRY_NAME))" = null ] && \
	  docker network connect kind $(REGISTRY_NAME) || true
	kubectl wait --for=condition=Ready nodes --all --timeout=180s
	kubectl label node -l '!node-role.kubernetes.io/control-plane' \
	  node-role.kubernetes.io/worker=true workload=agent --overwrite
	kubectl create configmap local-registry-hosting -n kube-public \
	  --from-literal=localRegistryHosting.v1='host: "localhost:$(REGISTRY_PORT)"' \
	  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	kubectl get nodes -o wide

up: deps registry cluster

build:
	DOCKER_BUILDKIT=1 docker build -f app/Dockerfile -t $(IMAGE):$(IMAGE_TAG) .

push:
	docker push $(IMAGE):$(IMAGE_TAG)

deploy:
	helm upgrade --install $(RELEASE) k8s/agent \
	  --namespace $(NAMESPACE) --create-namespace \
	  --set image.repository=$(IMAGE) \
	  --set image.tag=$(IMAGE_TAG) \
	  --set-string podAnnotations.rolledAt=$$(date +%s)
	kubectl -n $(NAMESPACE) get pods -l app=agent -o wide

all: up build push deploy

smoke:
	@kubectl get nodes -o wide
	test "$$(kubectl get nodes --no-headers | grep -c Ready)" = 3
	curl -fsS http://localhost:$(REGISTRY_PORT)/v2/_catalog
	[ "$$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' $(REGISTRY_NAME))" != null ]
	docker exec $(CLUSTER_NAME)-worker cat /etc/containerd/certs.d/localhost:$(REGISTRY_PORT)/hosts.toml
	test "$$(docker image inspect $(IMAGE):$(IMAGE_TAG) --format '{{.Config.User}}')" = "10001:10001"
	test "$$(docker image inspect $(IMAGE):$(IMAGE_TAG) --format '{{.Size}}')" -lt $$(($(MAX_IMAGE_MB)*1000*1000))
	! docker run --rm --entrypoint sh $(IMAGE):$(IMAGE_TAG) -c 'command -v uv' >/dev/null 2>&1
	kubectl -n $(NAMESPACE) rollout status deploy/agent --timeout=180s
	test "$$(kubectl -n $(NAMESPACE) get pods -l app=agent -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)" = 2
	kubectl -n $(NAMESPACE) exec deploy/agent -- id | grep -q uid=10001
	! kubectl -n $(NAMESPACE) exec deploy/agent -- touch /x
	kubectl -n $(NAMESPACE) exec deploy/agent -- touch /tmp/probe
	kubectl -n $(NAMESPACE) run curl-smoke --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
	  curl -fsS http://agent.$(NAMESPACE).svc.cluster.local/healthz
	echo "SMOKE OK"

# the registry is a separate container, so it survives `down` with every
# cached image layer intact — `clean` is what actually throws that away.
down:
	-kind delete cluster --name $(CLUSTER_NAME)

clean: down
	-docker rm -f $(REGISTRY_NAME)
