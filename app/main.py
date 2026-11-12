"""CareGuide API - a small FastAPI service built for the DevOps assessment."""

from __future__ import annotations

import logging
import os
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from starlette.routing import Match

from app.config import settings
from app.logging_config import configure_logging
from app.metrics import APP_INFO, IN_PROGRESS, REQUEST_COUNT, REQUEST_ERRORS, REQUEST_LATENCY

configure_logging(settings.log_level, settings.app_name, settings.environment, settings.app_version)
logger = logging.getLogger("careguide")

# Paths excluded from the access log (noise from probes/scrapers). Still counted in metrics.
QUIET_PATHS = {"/health", "/metrics"}


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    APP_INFO.info({"version": settings.app_version, "environment": settings.environment})
    logger.info("application started", extra={"port": settings.port})
    yield
    # Runs after uvicorn receives SIGTERM/SIGINT and in-flight requests have drained.
    logger.info("application shutting down gracefully")


app = FastAPI(title="CareGuide API", version=settings.app_version, lifespan=lifespan)


def _route_template(request: Request) -> str:
    """Return the matched route path (e.g. /items/{id}) to keep metric label cardinality bounded."""
    for route in request.app.router.routes:
        match, _ = route.matches(request.scope)
        if match == Match.FULL:
            return getattr(route, "path", request.url.path)
    return "unmatched"


@app.middleware("http")
async def observe_requests(
    request: Request, call_next: Callable[[Request], Awaitable[Response]]
) -> Response:
    path = _route_template(request)
    method = request.method
    start = time.perf_counter()
    status = 500
    IN_PROGRESS.inc()
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    except Exception:
        logger.exception("unhandled exception", extra={"path": path, "method": method})
        return JSONResponse({"detail": "Internal Server Error"}, status_code=500)
    finally:
        duration = time.perf_counter() - start
        IN_PROGRESS.dec()
        REQUEST_COUNT.labels(method=method, path=path, status=str(status)).inc()
        REQUEST_LATENCY.labels(method=method, path=path).observe(duration)
        if status >= 500:
            REQUEST_ERRORS.labels(method=method, path=path).inc()
        if path not in QUIET_PATHS:
            log = logger.error if status >= 500 else logger.info
            log(
                "request completed",
                extra={
                    "method": method,
                    "path": path,
                    "status": status,
                    "duration_ms": round(duration * 1000, 2),
                    "client": request.client.host if request.client else None,
                },
            )


@app.get("/")
async def root() -> dict[str, str]:
    return {
        "message": "Hello from DevOps Task!",
        "status": "running",
        "version": settings.app_version,
    }


@app.get("/health")
async def health() -> dict[str, str]:
    # Process is up and the event loop is responsive. With no downstream dependencies,
    # liveness and readiness are the same check.
    return {"status": "ok"}


@app.get("/metrics")
async def metrics() -> Response:
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


# Optional fault-injection endpoint used to demo alerts/dashboards. Disabled by default.
if os.getenv("CHAOS_ENABLED", "false").lower() == "true":

    @app.get("/chaos/error")
    async def chaos_error() -> None:
        raise HTTPException(status_code=500, detail="simulated failure")


def run() -> None:
    uvicorn.run(
        "app.main:app",
        host=settings.host,
        port=settings.port,
        log_config=None,  # keep our JSON logging
        access_log=False,
        proxy_headers=True,
        timeout_graceful_shutdown=20,  # < k8s terminationGracePeriodSeconds (30s)
    )


if __name__ == "__main__":
    run()
