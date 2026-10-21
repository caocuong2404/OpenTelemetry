# OpenTelemetry instance

A local OpenTelemetry backend with a **web UI**, running Grafana's all-in-one
[`grafana/otel-lgtm`](https://hub.docker.com/r/grafana/otel-lgtm) image, pinned in
[`.env`](.env) (`LGTM_VERSION`).

One container bundles the **OpenTelemetry Collector** plus **Prometheus** (metrics), **Tempo**
(traces), **Loki** (logs), **Pyroscope** (profiles) and **Grafana**, already wired to each other.
Point any OTLP exporter at it and the data shows up in the UI.

> Intended for development, demo and testing — not production.

## Run it

```bash
docker compose up -d
```

Then open **http://127.0.0.1:3000** and log in with `admin` / `admin` (override in
[`.env`](.env)). Stop with `docker compose down`. Bump the version by editing `LGTM_VERSION` in
[`.env`](.env) and re-running `docker compose up -d`.

## Ports

| Port  | What                                    |
| ----- | --------------------------------------- |
| 3000  | **Grafana web UI** — http://127.0.0.1:3000 |
| 4317  | OTLP receiver, gRPC                      |
| 4318  | OTLP receiver, HTTP/protobuf + HTTP/JSON |
| 9090  | Prometheus                               |
| 3200  | Tempo                                    |
| 3100  | Loki                                     |
| 4040  | Pyroscope                                |

Loki's 3100 is mapped on the host here so logs are queryable directly; upstream's own
`run-lgtm.sh` leaves it unpublished and reaches Loki only from inside the container.

## Send it telemetry

Anything that speaks OTLP works. Point it at `localhost:4317` (gRPC) or `localhost:4318` (HTTP).
For an ad-hoc check without an SDK, post OTLP/HTTP JSON:

```bash
curl -X POST http://localhost:4318/v1/logs \
  -H 'Content-Type: application/json' \
  -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"manual"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"1761000000000000000","body":{"stringValue":"hello otel"}}]}]}]}'
```

Then explore it in Grafana (Explore → Loki).

## Verify

```bash
./scripts/smoke-test.sh
```

Posts one span, one metric data point and one log record over OTLP/HTTP, then asserts each is
**queryable from the backend that stores it** — the trace in Tempo, the metric in Prometheus, the
log in Loki — plus that the Grafana UI answers. Polls with a timeout rather than sleeping a fixed
interval, and exits non-zero on any failure.

## Layout

```
docker-compose.yml     the instance
scripts/smoke-test.sh  end-to-end verification
```

Each component writes under `/data` in the container. That is backed by the **named volume**
`otel-instance_lgtm-data`, so state survives container recreation.

> **Do not bind-mount a host directory over `/data`.** Loki's ingester keeps a WAL-backed store
> and will not run it on a macOS virtiofs bind mount: it accepts no pushes and answers every
> write with `503 Ingester is shutting down`, while queries keep working — so traces and metrics
> look fine and only logs silently fail. This was reproduced with `./data:/data` and confirmed
> fixed by the named volume.

## Customising

Grafana is configured with `GF_*` environment variables (see `.env`). To change the backends
themselves, mount a config over the path the image documents — Prometheus at
`/otel-lgtm/prometheus.yaml`, Tempo at `/otel-lgtm/tempo-config.yaml`, Loki at
`/otel-lgtm/loki-config.yaml`, Pyroscope at `/otel-lgtm/pyroscope-config.yaml`, or the collector at
`/otel-lgtm/otelcol-config.yaml`. Each also takes a `*_EXTRA_ARGS` variable for one-off flags (see
[`docker-compose.yml`](docker-compose.yml), which sets `PROMETHEUS_EXTRA_ARGS` for retention).

Overriding `otelcol-config.yaml` **replaces** the collector's base config, including the exporters
that feed Prometheus/Tempo/Loki — do that only if you intend to re-wire those yourself. The image
can also forward on to a vendor via `OTEL_EXPORTER_OTLP_ENDPOINT`.

## History

This previously ran `otel/opentelemetry-collector-contrib` on its own, writing traces/metrics/logs
to local JSON files with no UI. It was migrated to `grafana/otel-lgtm` to get a real queryable
backend; the OTLP ingress (4317/4318) is unchanged, so existing exporters keep working.
