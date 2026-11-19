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

# Run a PromQL query and print how many series came back
series_count() {
    curl -fsS --get "$PROM_URL/api/v1/query" --data-urlencode "query=$1" | jq '.data.result | length'
}

# Run a check function until it passes, giving up after about 90 seconds.
# Everything starts at once, so the first scrape or probe often happens before
# the thing it's checking is listening. Retrying avoids failing on that race.
check() {
    local description="$1"
    shift
    for _ in $(seq 1 45); do
        if "$@" > /dev/null 2>&1; then
            echo "ok: $description"
            return 0
        fi
        sleep 2
    done
    echo "FAIL: $description" >&2
    # Run it once more with output showing, so the CI log says why
    echo "Last attempt output:" >&2
    "$@" >&2 || true
    exit 1
}

all_targets_up() {
    local targets
    targets=$(curl -fsS "$PROM_URL/api/v1/targets")
    jq -r '.data.activeTargets[] | "\(.labels.job) \(.health) \(.lastError)"' <<< "$targets"
    [[ "$(jq '.data.activeTargets | length' <<< "$targets")" -gt 0 ]] &&
        [[ "$(jq '[.data.activeTargets[] | select(.health != "up")] | length' <<< "$targets")" -eq 0 ]]
}

has_series() {
    local count
    count=$(series_count "$1")
    echo "$1 returned $count series"
    [[ "$count" -gt 0 ]]
}

rules_loaded() {
    [[ "$(curl -fsS "$PROM_URL/api/v1/rules" | jq '[.data.groups[].rules[]] | length')" -gt 0 ]]
}

grafana_healthy() {
    curl -fsS "$GRAFANA_URL/api/health" | jq -e '.database == "ok"'
}

dashboard_provisioned() {
    curl -fsS -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
        "$GRAFANA_URL/api/search?query=Linux%20Host%20Overview" | jq -e 'length >= 1'
}

grafana_can_query_prometheus() {
    curl -fsS -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
        "$GRAFANA_URL/api/datasources/uid/prometheus/health" | jq -e '.status == "OK"'
}

check "every scrape target is healthy" all_targets_up
check "node_exporter metrics arriving" has_series 'node_memory_MemTotal_bytes'
check "TCP probe metrics arriving" has_series 'tcp_probe_up'
check "TCP exporter can reach Prometheus" has_series 'tcp_probe_up{target="prometheus"} == 1'
check "alert rules loaded" rules_loaded

if [[ "${SKIP_GRAFANA:-0}" == "1" ]]; then
    echo "Skipping Grafana checks"
    exit 0
fi

check "Grafana healthy" grafana_healthy
check "dashboard provisioned" dashboard_provisioned
check "Grafana can query Prometheus" grafana_can_query_prometheus

echo "All smoke tests passed"
