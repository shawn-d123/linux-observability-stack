#!/usr/bin/env bash
# Starts the monitoring stack and waits until Prometheus and Grafana answer.
#
# Usage:
#   ./scripts/setup.sh         start (or restart) the stack
#   ./scripts/setup.sh --down  stop it and keep the stored data
set -euo pipefail

cd "$(dirname "$0")/.."

PROM_URL="${PROM_URL:-http://localhost:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"

if ! command -v docker > /dev/null; then
    echo "Docker isn't installed. See https://docs.docker.com/engine/install/" >&2
    exit 1
fi
if ! docker compose version > /dev/null 2>&1; then
    echo "The docker compose plugin is missing." >&2
    exit 1
fi

if [[ "${1:-}" == "--down" ]]; then
    docker compose down
    exit 0
fi

if [[ ! -f .env ]]; then
    cp .env.example .env
    echo "Created .env from .env.example. Change GRAFANA_ADMIN_PASSWORD before exposing Grafana."
fi

docker compose up -d --build

# Wait for a URL to return 200, giving up after about a minute
wait_for() {
    local name="$1" url="$2"
    for _ in $(seq 1 30); do
        if curl -fsS "$url" > /dev/null 2>&1; then
            echo "$name is up"
            return 0
        fi
        sleep 2
    done
    echo "$name didn't come up at $url. Check: docker compose logs" >&2
    return 1
}

wait_for "Prometheus" "$PROM_URL/-/ready"
wait_for "Grafana" "$GRAFANA_URL/api/health"

echo
echo "Grafana:    $GRAFANA_URL  (dashboard: Linux Host Overview)"
echo "Prometheus: $PROM_URL/alerts"
