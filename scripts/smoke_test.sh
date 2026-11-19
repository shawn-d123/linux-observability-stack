#!/usr/bin/env bash
# Checks a running stack does what it claims: every scrape target is healthy,
# host and TCP metrics are arriving, the alert rules loaded and Grafana has the
# dashboard. Exits non-zero on the first failure, which is what CI looks for.
#
# Needs curl and jq. Set SKIP_GRAFANA=1 to check Prometheus on its own.
set -euo pipefail

cd "$(dirname "$0")/.."

PROM_URL="${PROM_URL:-http://localhost:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"

if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    source .env
fi
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-change-me}"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# Run a PromQL query and print how many series came back
series_count() {
    curl -fsS --get "$PROM_URL/api/v1/query" --data-urlencode "query=$1" | jq '.data.result | length'
}

# Targets can take a scrape or two to turn healthy, so retry for up to a minute
echo "Waiting for every scrape target to be healthy..."
for attempt in $(seq 1 30); do
    unhealthy=$(curl -fsS "$PROM_URL/api/v1/targets" \
        | jq '[.data.activeTargets[] | select(.health != "up")] | length')
    total=$(curl -fsS "$PROM_URL/api/v1/targets" | jq '.data.activeTargets | length')
    if [[ "$total" -gt 0 && "$unhealthy" -eq 0 ]]; then
        echo "ok: all $total targets up"
        break
    fi
    if [[ "$attempt" -eq 30 ]]; then
        fail "$unhealthy of $total scrape targets still unhealthy"
    fi
    sleep 2
done

[[ "$(series_count 'node_memory_MemTotal_bytes')" -gt 0 ]] || fail "no host memory metrics from node_exporter"
echo "ok: node_exporter metrics arriving"

[[ "$(series_count 'tcp_probe_up')" -gt 0 ]] || fail "no tcp_probe_up series from the TCP exporter"
echo "ok: TCP probe metrics arriving"

[[ "$(series_count 'tcp_probe_up{target="prometheus"} == 1')" -eq 1 ]] \
    || fail "TCP exporter can't reach Prometheus"
echo "ok: TCP exporter can reach Prometheus"

rules=$(curl -fsS "$PROM_URL/api/v1/rules" | jq '[.data.groups[].rules[]] | length')
[[ "$rules" -gt 0 ]] || fail "no alert rules loaded"
echo "ok: $rules alert rules loaded"

if [[ "${SKIP_GRAFANA:-0}" == "1" ]]; then
    echo "Skipping Grafana checks"
    exit 0
fi

curl -fsS "$GRAFANA_URL/api/health" | jq -e '.database == "ok"' > /dev/null || fail "Grafana isn't healthy"
echo "ok: Grafana healthy"

found=$(curl -fsS -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
    "$GRAFANA_URL/api/search?query=Linux%20Host%20Overview" | jq 'length')
[[ "$found" -ge 1 ]] || fail "Linux Host Overview dashboard wasn't provisioned"
echo "ok: dashboard provisioned"

datasource=$(curl -fsS -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
    "$GRAFANA_URL/api/datasources/uid/prometheus/health" | jq -r '.status')
[[ "$datasource" == "OK" ]] || fail "Grafana can't query Prometheus (status: $datasource)"
echo "ok: Grafana can query Prometheus"

echo "All smoke tests passed"
