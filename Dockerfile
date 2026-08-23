# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the Agent service.
#   builder  — uv resolves and installs dependencies into /opt/venv
#   runtime  — python:3.12-slim + that venv + app source, running as uid 10001
#
# The runtime stage contains no uv, no compiler toolchain and no apt cache.
# Requires BuildKit (cache mounts): DOCKER_BUILDKIT=1.

# Both stages share one digest-pinned base so the venv is built against exactly
# the interpreter and glibc that will run it. -bookworm is explicit on purpose:
# the floating `3.12-slim` tag moves between Debian releases.
ARG PYTHON_BASE=python:3.12-slim-bookworm@sha256:a116514e19457bcb7af7efe9c3dd0b9b71e85b317694e7882a1c52aa15a78134
# uv is pinned by exact version and only ever exists in the builder stage.
ARG UV_VERSION=0.12.5

# --------------------------------------------------------------------------- #
# Stage: uv — a scratch-thin image that carries nothing but the uv binary.
# --------------------------------------------------------------------------- #
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# --------------------------------------------------------------------------- #
# Stage: builder
# --------------------------------------------------------------------------- #
FROM ${PYTHON_BASE} AS builder

COPY --from=uv /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/venv

WORKDIR /src

# The Agent service is its own uv project under app/; the build context is the
# repository root so the Dockerfile and .dockerignore stay at the top level.
#
# Phase 1 — dependencies only. This layer is keyed on pyproject.toml + uv.lock,
# so editing source never re-resolves or re-downloads a single wheel.
# --locked (not --frozen): the build FAILS if uv.lock is stale relative to
# pyproject.toml, instead of silently resolving something the lockfile never
# recorded.
COPY app/pyproject.toml app/uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --no-install-project

# Phase 2 — install the project itself. --no-editable is required: uv installs
# the project editable by default, which would leave a .pth file pointing at
# /src in a venv that gets copied into a stage where /src does not exist.
COPY app/app/ ./app/
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --no-editable

# The uv cache lives exclusively in the cache mount above — it is never
# committed to a layer.

# --------------------------------------------------------------------------- #
# Stage: runtime
# --------------------------------------------------------------------------- #
FROM ${PYTHON_BASE} AS runtime

ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG BUILD_DATE
ARG SOURCE_URL=https://example.invalid/agent

LABEL org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.title="agent" \
      org.opencontainers.image.description="Agent service"

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

# Fixed numeric IDs so the image's identity matches the Pod securityContext
# (runAsUser/runAsGroup/fsGroup 10001) exactly. -M: no home directory to write
# into; nologin: the account cannot be used for a shell.
RUN groupadd --gid 10001 agentsvc \
 && useradd --uid 10001 --gid 10001 -M -s /usr/sbin/nologin agentsvc

COPY --from=builder --chown=10001:10001 /opt/venv /opt/venv

WORKDIR /app
COPY --chown=10001:10001 app/app/ ./app/

# MUST be numeric: Kubernetes `runAsNonRoot: true` cannot resolve a username to
# a uid, and a Pod whose image declares a non-numeric USER fails to start with
# CreateContainerConfigError.
USER 10001:10001

EXPOSE 8000

# Uses the venv's own interpreter — no curl/wget installed, so the runtime layer
# stays free of apt and its caches.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2).status == 200 else 1)"]

# Exec form: uvicorn becomes PID 1 and receives SIGTERM directly, so a Pod
# deletion drains instead of waiting out terminationGracePeriodSeconds.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
