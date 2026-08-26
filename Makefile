.DEFAULT_GOAL := help
SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

CLUSTER_NAME   ?= ai-platform-cluster
KIND_CONFIG    ?= k8s/kind-config.yaml
METRICS_SERVER_VERSION ?= v0.7.2
ARGOCD_VERSION         ?= v3.4.6
# Argo CD follows the branch checked out when `make gitops` runs. Fall back to
# main for detached HEADs, while still allowing an explicit override.
GITOPS_BRANCH          ?= $(shell git symbolic-ref --quiet --short HEAD 2>/dev/null || printf '%s' main)

# One container under two names: localhost:5001 from the host, kind-registry:5000
# from the nodes.
REGISTRY_NAME  ?= kind-registry
REGISTRY_PORT  ?= 5001
REGISTRY_IMAGE ?= registry:3

IMAGE          ?= localhost:$(REGISTRY_PORT)/agent
# The image is built from app/, so the commit that last touched it names it.
IMAGE_TAG      ?= $(shell git log -1 --format=%h -- app)
NAMESPACE      ?= ai-platform

.PHONY: help deps registry cluster up build push \
	deploy deploy-qdrant deploy-ollama deploy-agent deploy-monitoring \
	install-argocd gitops release all smoke down clean

help:
	@echo "make deps     check that docker, kind, kubectl, helm and jq are installed"
	echo "make up       local registry + 3-node cluster"
	echo "make build    build $(IMAGE):$(IMAGE_TAG)"
	echo "make push     push it to the local registry"
	echo "make deploy   install the application and monitoring charts, bypassing Argo CD"
	echo "make gitops   install Argo CD and enable automatic chart sync"
	echo "make release  push the image and record its tag in git for Argo CD"
	echo "make all      up + release + gitops"
	echo "make smoke    end-to-end checks"
	echo "make down     delete the cluster"
	echo "make clean    delete the cluster and the registry"

deps:
	@for tool in docker kind kubectl helm jq; do
	  command -v "$$tool" >/dev/null || { echo "$$tool is not installed" >&2; exit 1; }
	done
	docker info >/dev/null 2>&1 || { echo "docker is not running" >&2; exit 1; }
	test -f app/uv.lock || { echo "app/uv.lock missing - run: uv lock --directory app" >&2; exit 1; }
	echo "deps ok"

# `docker start` is a no-op when the container is already running and fails when
# there is none, so these two lines cover all three states.
registry:
	@docker start $(REGISTRY_NAME) >/dev/null 2>&1 || \
	  docker run -d --name $(REGISTRY_NAME) --restart=always \
	    -p 127.0.0.1:$(REGISTRY_PORT):5000 $(REGISTRY_IMAGE) >/dev/null
	curl -fsS --retry 10 --retry-delay 2 --retry-connrefused \
	  http://localhost:$(REGISTRY_PORT)/v2/_catalog >/dev/null

# No --image: kind uses the node image it shipped with, so the two cannot drift.
# The Kubernetes version follows whoever's kind is installed, and helm enforces
# the chart's kubeVersion floor.
cluster:
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER_NAME) || \
	  kind create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG) --wait 180s
	kubectl config use-context kind-$(CLUSTER_NAME) >/dev/null

	# kind-config.yaml points containerd at /etc/containerd/certs.d. This is the entry
	# that makes localhost:5001/agent resolve to the registry container.
	for node in $$(kind get nodes --name $(CLUSTER_NAME)); do
	  docker exec "$$node" mkdir -p /etc/containerd/certs.d/localhost:$(REGISTRY_PORT)
	  echo '[host."http://$(REGISTRY_NAME):5000"]' | \
	    docker exec -i "$$node" tee /etc/containerd/certs.d/localhost:$(REGISTRY_PORT)/hosts.toml >/dev/null
	done
	docker network connect kind $(REGISTRY_NAME) 2>/dev/null || true
	kubectl wait --for=condition=Ready nodes --all --timeout=180s

	# The HPA needs metrics-server, and kind's kubelets serve metrics with self-signed
	# certs it rejects unless told not to.
	kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/$(METRICS_SERVER_VERSION)/components.yaml" >/dev/null
	kubectl -n kube-system get deploy metrics-server -o jsonpath='{..args}' | grep -q insecure-tls || \
	  kubectl -n kube-system patch deployment metrics-server --type=json \
	    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null
	kubectl -n kube-system rollout status deploy/metrics-server --timeout=90s

	kubectl get nodes -o wide

up: deps registry cluster

# Built from the repository root, because the Dockerfile copies app/.
build:
	@DOCKER_BUILDKIT=1 docker build -f app/Dockerfile -t $(IMAGE):$(IMAGE_TAG) .

push: build
	@docker push $(IMAGE):$(IMAGE_TAG)

deploy: deploy-qdrant deploy-ollama deploy-agent deploy-monitoring

deploy-qdrant:
	@ls k8s/qdrant/charts/*.tgz >/dev/null 2>&1 || helm dependency build k8s/qdrant
	helm upgrade --install qdrant k8s/qdrant -n $(NAMESPACE) --create-namespace

# The first install pulls the models in an init container and takes minutes to report
# Ready. Later ones hit the cached volume.
deploy-ollama:
	@helm upgrade --install ollama k8s/ollama -n $(NAMESPACE) --create-namespace

# Bypasses Argo CD, for the inner loop. The tag only moves when app/ is
# committed, so the timestamp is what rolls the Pods in between.
deploy-agent:
	@helm upgrade --install agent k8s/agent -n $(NAMESPACE) --create-namespace \
	  --set image.repository=$(IMAGE) --set image.tag=$(IMAGE_TAG) \
	  --set-string podAnnotations.rolledAt=$$(date +%s)
	kubectl -n $(NAMESPACE) get pods -o wide

deploy-monitoring:
	@ls k8s/observability/charts/*.tgz >/dev/null 2>&1 || helm dependency update k8s/observability
	helm upgrade --install monitoring k8s/observability -n $(NAMESPACE) --create-namespace

install-argocd:
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	# --server-side: the applicationsets CRD is too big for the apply annotation.
	kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
	kubectl -n argocd wait --for=condition=Available deployment --all --timeout=180s

gitops: install-argocd
	sed 's|targetRevision: main|targetRevision: $(GITOPS_BRANCH)|g' k8s/argocd/applications.yaml | kubectl apply -f -

# A release always comes from $(GITOPS_BRANCH), whatever is checked out here: it is
# built in a throwaway worktree of that branch and the tag is committed onto it.
release:
	git fetch -q origin $(GITOPS_BRANCH)
	work=$$(mktemp -d)
	git worktree add -q --detach "$$work" origin/$(GITOPS_BRANCH)
	trap 'git worktree remove --force "$$work"' EXIT
	tag=$$(git -C "$$work" log -1 --format=%h -- app)
	$(MAKE) -C "$$work" push IMAGE_TAG="$$tag"
	sed -i "s|^  tag: .*|  tag: $$tag|" "$$work/k8s/agent/values.yaml"
	git -C "$$work" diff --quiet || git -C "$$work" commit -aqm "release: agent $$tag"
	git -C "$$work" push origin HEAD:$(GITOPS_BRANCH)

all: up release gitops

smoke:
	@NAMESPACE=$(NAMESPACE) bash scripts/smoke.sh

down:
	-kind delete cluster --name $(CLUSTER_NAME)

clean: down
	-docker rm -f $(REGISTRY_NAME)
