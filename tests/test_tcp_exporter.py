"""Tests for the TCP exporter, run with: pytest"""
import socket
import sys
from pathlib import Path

import pytest
from prometheus_client import REGISTRY

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "exporter"))
import tcp_exporter  # noqa: E402


@pytest.fixture
def listening_port():
    """Open a local socket that accepts connections and give back its port."""
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(("127.0.0.1", 0))
    server.listen()
    yield server.getsockname()[1]
    server.close()


@pytest.fixture
def closed_port():
    """Find a port with nothing listening on it."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def write_targets(tmp_path, text):
    path = tmp_path / "targets.yml"
    path.write_text(text, encoding="utf-8")
    return path


def test_load_targets_reads_every_entry(tmp_path):
    path = write_targets(tmp_path, """
targets:
  - {name: web, host: example.com, port: 443}
  - {name: db, host: 10.0.0.5, port: 5432}
""")
    assert tcp_exporter.load_targets(path) == [("web", "example.com", 443), ("db", "10.0.0.5", 5432)]


def test_load_targets_rejects_missing_port(tmp_path):
    path = write_targets(tmp_path, "targets:\n  - {name: web, host: example.com}\n")
    with pytest.raises(ValueError):
        tcp_exporter.load_targets(path)


def test_load_targets_rejects_port_out_of_range(tmp_path):
    path = write_targets(tmp_path, "targets:\n  - {name: web, host: example.com, port: 70000}\n")
    with pytest.raises(ValueError):
        tcp_exporter.load_targets(path)


def test_load_targets_rejects_empty_file(tmp_path):
    path = write_targets(tmp_path, "")
    with pytest.raises(ValueError):
        tcp_exporter.load_targets(path)


def test_probe_succeeds_on_open_port(listening_port):
    worked, seconds = tcp_exporter.probe("127.0.0.1", listening_port, timeout=1)
    assert worked
    assert 0 <= seconds < 1


def test_probe_fails_on_closed_port(closed_port):
    worked, _ = tcp_exporter.probe("127.0.0.1", closed_port, timeout=1)
    assert not worked


def test_probe_fails_on_unknown_host():
    # .invalid is reserved and never resolves
    worked, _ = tcp_exporter.probe("no-such-host.invalid", 80, timeout=1)
    assert not worked


def test_run_once_sets_metrics(listening_port, closed_port):
    targets = [("open-svc", "127.0.0.1", listening_port), ("closed-svc", "127.0.0.1", closed_port)]
    tcp_exporter.run_once(targets, timeout=1)

    def sample(name, **labels):
        return REGISTRY.get_sample_value(name, labels)

    assert sample("tcp_probe_up", target="open-svc") == 1
    assert sample("tcp_probe_up", target="closed-svc") == 0
    assert sample("tcp_probe_connect_seconds", target="open-svc") is not None
    # A failed probe shouldn't leave a connect time behind
    assert sample("tcp_probe_connect_seconds", target="closed-svc") is None
    assert sample("tcp_probe_checks_total", target="closed-svc", result="failure") >= 1
