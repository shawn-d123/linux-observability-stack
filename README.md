# Linux Host Observability Stack

A small monitoring stack for a Linux machine, built with Prometheus, node_exporter and Grafana in Docker Compose. It also includes a Python exporter I wrote that checks how long it takes to open a TCP connection to the services you care about.

Run one command and you get a Grafana dashboard showing CPU, memory, disk and network use, plus whether each endpoint is reachable and how quickly it answers. Alert rules fire when a disk is filling up, a scrape target drops out or an endpoint stops answering.

## What's in it

| Service | What it does | Port |
|---|---|---|
| Prometheus | Scrapes and stores the metrics and evaluates the alert rules | 9090 |
| node_exporter | Exposes the host's CPU, memory, disk and network stats from `/proc` and `/sys` | 9100 (internal) |
| tcp-exporter | My Python exporter. Opens a TCP connection to each target every 15 seconds and records whether it worked and how long it took | 9105 (internal) |
| Grafana | Shows the "Linux Host Overview" dashboard. The data source and dashboard are provisioned from files, so nothing is set up by hand | 3000 |

```
node_exporter ──┐
                ├──> Prometheus ──> Grafana dashboard
tcp-exporter  ──┘        │
                         └──> alert rules (alerts.yml)
```

## Running it

You need Docker with the Compose plugin on a Linux machine. A Raspberry Pi running a 64-bit OS works too.

```bash
git clone https://github.com/shawn-d123/linux-observability-stack.git
cd linux-observability-stack
./scripts/setup.sh
```

`setup.sh` checks Docker is installed, creates `.env` from `.env.example` if you don't have one, builds the exporter, starts everything and waits until Prometheus and Grafana respond. Then open:

- Grafana at http://localhost:3000 (log in with the user and password from `.env`)
- Prometheus alerts at http://localhost:9090/alerts

To stop it and keep the stored data, run `./scripts/setup.sh --down`.

On Docker Desktop for Windows or macOS, node_exporter reports on the Linux VM that Docker runs in, not the host operating system. Everything still works, but the numbers describe that VM.

## The TCP exporter

`exporter/tcp_exporter.py` reads its list of targets from `exporter/targets.yml`:

```yaml
targets:
  - name: github
    host: github.com
    port: 443
```

For each target it exposes:

- `tcp_probe_up` is 1 if the last connection opened and 0 if it failed (refused, timed out, or the name didn't resolve)
- `tcp_probe_connect_seconds` is how long the last successful connection took to open. Failed probes are left out on purpose, because their time is usually just the timeout and would make the graph misleading.
- `tcp_probe_checks_total` counts every probe, split by success and failure

To check your own services, add them to `targets.yml` and restart the exporter with `docker compose restart tcp-exporter`. The interval and timeout are set with `PROBE_INTERVAL` and `PROBE_TIMEOUT` in `docker-compose.yml`.

## Alerts

The rules live in `prometheus/alerts.yml`:

| Alert | Fires when |
|---|---|
| InstanceDown | A scrape target hasn't answered for 1 minute |
| HighCpuUsage | CPU has been above 90% for 10 minutes |
| HighMemoryUsage | Memory has been more than 90% used for 10 minutes |
| DiskAlmostFull | A real filesystem has less than 10% free for 5 minutes (tmpfs and overlay mounts are ignored) |
| DiskFillingUp | The last 6 hours of free space, projected forwards, run out within 24 hours |
| EndpointDown | A TCP target has failed for 2 minutes |
| SlowTcpConnect | A TCP target has taken over 500 ms to connect for 5 minutes |

The thresholds are starting points. A busy build server will want a higher CPU limit than a Pi sitting idle.

## Tests

The checks below run in GitHub Actions on every push:

- **Exporter unit tests** (`pytest`): parsing the targets file, rejecting bad entries, and probing a real local socket that is open, closed or has a name that won't resolve.
- **Alert rule tests** (`promtool test rules tests/alerts_test.yml`): feed made-up series into the rules and check that each alert fires at the right time and stays quiet when it should, for example that tmpfs mounts never trigger DiskAlmostFull.
- **Config checks**: `promtool check config`, valid dashboard JSON and `shellcheck` on the scripts.
- **Smoke test** (`scripts/smoke_test.sh`): starts the whole stack in Docker, then confirms every scrape target is healthy, host and TCP metrics are arriving, the alert rules are loaded, Grafana has provisioned the dashboard and Grafana can query Prometheus.

To run them locally:

```bash
pip install -r exporter/requirements.txt pytest
pytest
./scripts/setup.sh && ./scripts/smoke_test.sh
```

## Layout

```
docker-compose.yml
exporter/            Python TCP exporter, its Dockerfile and targets
prometheus/          scrape config and alert rules
grafana/             provisioned data source and the dashboard JSON
scripts/             setup.sh and smoke_test.sh
tests/               pytest tests and promtool alert tests
.github/workflows/   CI
```

## Ideas for later

- Add Alertmanager so alerts reach email or a chat channel instead of just the Prometheus UI
- Run node_exporter on more than one machine and add a host picker to the dashboard
- Track connection time as a histogram so the dashboard can show percentiles rather than the last value
