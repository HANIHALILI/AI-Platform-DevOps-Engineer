#!/usr/bin/env bash
# Verify every dependency, installing the ones that can be installed safely.
#
# kind, kubectl and helm are single static binaries: they go into BIN_DIR with
# no sudo and no system state. Docker is deliberately NOT installed here — it
# needs root, a systemd unit and a group change that only takes effect after a
# re-login, so it is reported and left to you.
set -euo pipefail

KIND_VERSION="${KIND_VERSION:-v0.32.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.34.8}"   # matches the node image
HELM_VERSION="${HELM_VERSION:-v3.21.4}"         # the chart is apiVersion v2
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${APP_DIR:-app}"

case "$(uname -m)" in
  x86_64)        ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "deps: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

log()  { echo "deps: $*"; }
fail() { echo "deps: FAIL — $1" >&2; [ $# -gt 1 ] && echo "  fix: $2" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$BIN_DIR"

# --- docker: reported, never installed --------------------------------------
have docker || fail "docker is not installed" \
  "https://docs.docker.com/engine/install/ — then: sudo usermod -aG docker \$USER && newgrp docker"

docker info >/dev/null 2>&1 || fail "the docker daemon is not responding" \
  "sudo systemctl start docker — and make sure you are in the 'docker' group"

# The Dockerfile uses --mount=type=cache, which the legacy builder cannot do.
docker buildx version >/dev/null 2>&1 || fail "docker buildx is missing" \
  "install the docker-buildx-plugin package"

log "docker ok ($(docker --version))"

# --- kind -------------------------------------------------------------------
# The kindest/node digest in cluster-up.sh is built for this kind release, so an
# older kind is upgraded rather than accepted.
install_kind() {
  log "installing kind ${KIND_VERSION} -> ${BIN_DIR}/kind"
  curl -fsSL -o "${BIN_DIR}/kind" \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  chmod +x "${BIN_DIR}/kind"
}
if ! have kind; then
  install_kind
elif [ "$(printf '%s\n%s\n' "${KIND_VERSION#v}" "$(kind version -q)" | sort -V | head -n1)" != "${KIND_VERSION#v}" ]; then
  log "kind $(kind version -q) is older than ${KIND_VERSION}"
  install_kind
fi
log "kind ok ($(kind version -q))"

# --- kubectl ----------------------------------------------------------------
if ! have kubectl; then
  log "installing kubectl ${KUBECTL_VERSION} -> ${BIN_DIR}/kubectl"
  curl -fsSL -o "${BIN_DIR}/kubectl" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  chmod +x "${BIN_DIR}/kubectl"
fi
log "kubectl ok ($(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion/{print $2; exit}'))"

# --- helm -------------------------------------------------------------------
if ! have helm; then
  log "installing helm ${HELM_VERSION} -> ${BIN_DIR}/helm"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C "$tmp"
  install -m 0755 "$tmp/linux-${ARCH}/helm" "${BIN_DIR}/helm"
fi
log "helm ok ($(helm version --short))"

# --- the lockfile the image build needs -------------------------------------
[ -f "${APP_DIR}/uv.lock" ] || fail "${APP_DIR}/uv.lock is missing" \
  "uv lock --directory ${APP_DIR}"
log "${APP_DIR}/uv.lock ok"

# The Makefile prepends BIN_DIR to PATH for its own recipes, so a freshly
# installed binary works immediately. Interactive shells need it too.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) log "NOTE: ${BIN_DIR} is not on your PATH — add it for interactive use:"
     log "      echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
esac

log "all dependencies satisfied"
