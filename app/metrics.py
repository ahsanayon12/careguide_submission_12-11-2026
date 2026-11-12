"""Prometheus metrics definitions."""

from prometheus_client import Counter, Gauge, Histogram, Info

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "path", "status"],
)

REQUEST_ERRORS = Counter(
    "http_request_errors_total",
    "Total HTTP requests that resulted in a 5xx response or unhandled exception",
    ["method", "path"],
)

REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

IN_PROGRESS = Gauge(
    "http_requests_in_progress",
    "HTTP requests currently being processed",
)

APP_INFO = Info("app", "Application build information")
