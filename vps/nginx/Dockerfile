ARG NGINX_IMAGE
FROM ${NGINX_IMAGE}

# curl is not in the slim image: needed by the health check.
# One worker: "auto" would start one per CPU of the host for every site, while the
# container has half a CPU; a single worker handles 1024 connections.
RUN set -eux; \
    apk add --no-cache curl; \
    rm -f /etc/nginx/conf.d/default.conf; \
    sed -i 's/^worker_processes .*/worker_processes 1;/' /etc/nginx/nginx.conf; \
    grep -q '^worker_processes 1;' /etc/nginx/nginx.conf

# Templates are rendered with envsubst into /etc/nginx/conf.d at startup (official image feature), so the per-site values come from the environment.
COPY templates/ /etc/nginx/templates/
COPY snippets/ /etc/nginx/snippets/

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1:8080/healthz || exit 1
