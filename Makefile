# Agent service — local kind cluster, registry, image, Helm release.

.DEFAULT_GOAL := help

CLUSTER_NAME  ?= agent-cluster
REGISTRY_NAME ?= kind-registry
REGISTRY_PORT ?= 5001
IMAGE         ?= localhost:$(REGISTRY_PORT)/agent
IMAGE_TAG     ?= dev
RELEASE       ?= agent
NAMESPACE     ?= default

# Where deps.sh installs kind/kubectl/helm. Prepended to PATH so a binary it
# just installed is found by the very next recipe in the same `make` run.
BIN_DIR       ?= $(HOME)/.local/bin
export PATH   := $(BIN_DIR):$(PATH)

.PHONY: help deps up build push deploy all smoke down clean

help:
	@echo "make deps    check dependencies, install kind/kubectl/helm if missing"
	@echo "make up      deps + registry + 3-node cluster, wired together"
	@echo "make build   build $(IMAGE):$(IMAGE_TAG)"
	@echo "make push    push it to the local registry"
	@echo "make deploy  install/upgrade the Helm chart"
	@echo "make all     up + build + push + deploy"
	@echo "make smoke   verify the whole thing end to end"
	@echo "make down    delete the cluster, keep the registry and its cache"
	@echo "make clean   delete the cluster and the registry"

deps:
	@bash k8s/scripts/deps.sh

# Order is not arbitrary: the registry must exist before the cluster, and it can
# only join the `kind` docker network after the cluster has created it.
# cluster-up.sh does that join, writes the containerd mirror onto every node and
# labels the workers — without those three steps the registry and the cluster
# cannot talk.
up: deps
	@bash k8s/scripts/registry-up.sh
	@bash k8s/scripts/cluster-up.sh

build:
	DOCKER_BUILDKIT=1 docker build -t $(IMAGE):$(IMAGE_TAG) .

push:
	docker push $(IMAGE):$(IMAGE_TAG)

# rolledAt forces a re-pull: :dev is a moving tag, so without a change to the
# Pod template Helm reports "no changes" and keeps serving the previous image.
deploy:
	helm upgrade --install $(RELEASE) k8s/agent \
		--namespace $(NAMESPACE) --create-namespace \
		--set image.repository=$(IMAGE) \
		--set image.tag=$(IMAGE_TAG) \
		--set podAnnotations.rolledAt=$$(date +%s)
	kubectl -n $(NAMESPACE) get pods -l app=agent -o wide

all: up build push deploy

smoke:
	@bash k8s/scripts/smoke-test.sh

# The registry is a separate container, so it survives `down` with every cached
# image layer intact. `clean` is what actually throws that away.
down:
	-kind delete cluster --name $(CLUSTER_NAME)

clean: down
	-docker rm -f $(REGISTRY_NAME)
