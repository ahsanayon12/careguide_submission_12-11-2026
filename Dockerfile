# syntax=docker/dockerfile:1.7
#
# Multi-stage build:
#   1. builder  - full Debian/Python image, installs deps into /install
#   2. test     - optional target used by CI to run unit tests inside the image toolchain
#   3. runtime  - Google distroless Python (no shell, no package manager), runs as nonroot (65532)
#
# Base images are pinned to explicit versions. For byte-for-byte reproducibility, pin by digest:
#   docker buildx imagetools inspect python:3.11.14-slim-bookworm --format '{{json .Manifest.Digest}}'
# and replace the tag with  python:3.11.14-slim-bookworm@sha256:<digest>  (Renovate/Dependabot can keep it fresh).
# Distroless debian12 ships Python 3.11, so the builder MUST also be 3.11 for compiled wheels to match.

########################  builder  ########################
FROM python:3.11.14-slim-bookworm AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build

# Dependencies first => this layer is cached until requirements.txt changes.
COPY requirements.txt .
RUN pip install --no-compile --target=/install -r requirements.txt

########################  test  ###########################
FROM builder AS test
COPY requirements-dev.txt pyproject.toml ./
RUN pip install -r requirements-dev.txt
COPY app/ ./app/
COPY tests/ ./tests/
RUN python -m pytest -q

########################  runtime  ########################
FROM gcr.io/distroless/python3-debian12:nonroot AS runtime

ARG APP_VERSION=0.0.0-dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="careguide-api" \
      org.opencontainers.image.description="CareGuide demo web service (DevOps assessment)" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/<your-github-user>/CareGuide" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="gcr.io/distroless/python3-debian12:nonroot"

WORKDIR /app

COPY --from=builder --chown=65532:65532 /install /app/deps
COPY --chown=65532:65532 app/ /app/app/

ENV PYTHONPATH=/app/deps:/app \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION=${APP_VERSION} \
    PORT=8080 \
    LOG_LEVEL=INFO \
    ENVIRONMENT=production

# Distroless :nonroot already defaults to uid 65532; stated explicitly for scanners/reviewers.
USER 65532:65532

EXPOSE 8080

# No curl/wget in distroless, so the healthcheck uses the Python stdlib.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python3", "-c", "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/health' % os.environ.get('PORT','8080'), timeout=2)"]

# Exec form => python is PID 1 and receives SIGTERM directly; uvicorn drains then exits.
ENTRYPOINT ["python3", "-m", "app.main"]
