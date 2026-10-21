# OpenTelemetry instance

A local [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) instance running the
official **contrib** distribution from the [`otel` Docker Hub org](https://hub.docker.com/u/otel):
[`otel/opentelemetry-collector-contrib`](https://hub.docker.com/r/otel/opentelemetry-collector-contrib).
The version is pinned in [`.env`](.env) (`OTEL_COLLECTOR_VERSION`) — that file is the single source
of truth, and the instance will not start without it.

It accepts OTLP (gRPC and HTTP) from any instrumented service, and exports every signal to local
JSON files under [`data/`](data) plus the collector's own `debug` output, so the instance is usable
and verifiable without any external backend.

## Run it

```bash
docker compose up -d
```

Stop it with `docker compose down`. Bump the collector version by editing
[`OTEL_COLLECTOR_VERSION`](.env) and re-running `docker compose up -d`.

## Ports

| Port  | What                                        | Bound on |
| ----- | ------------------------------------------- | -------- |
| 4317  | OTLP receiver, gRPC                          | all      |
| 4318  | OTLP receiver, HTTP/protobuf + HTTP/JSON     | all      |
| 13133 | `health_check` extension — `GET /` → 200     | all      |
| 8888  | Collector self-metrics (Prometheus pull)     | all      |
| 55679 | `zpages` extension (live pipeline debug UI)  | loopback |
| 1777  | `pprof` extension                            | loopback |

The two debug extensions are published on `127.0.0.1` only: they are an inspection surface, not
part of the OTLP service. To drop them, remove `zpages`/`pprof` from `extensions:` and
`service.extensions` in [`config/otelcol-contrib.yaml`](config/otelcol-contrib.yaml) and from
`ports:` in [`docker-compose.yml`](docker-compose.yml).

## Send it telemetry

Anything that speaks OTLP works. Point it at `localhost:4317` (gRPC) or `localhost:4318` (HTTP).
For an ad-hoc check without an SDK, post OTLP/HTTP JSON:

```bash
curl -X POST http://localhost:4318/v1/logs \
  -H 'Content-Type: application/json' \
  -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"manual"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"1761000000000000000","body":{"stringValue":"hello otel"}}]}]}]}'
```

Then look at [`data/logs.json`](data/logs.json).

## Verify

```bash
./scripts/smoke-test.sh
```

Sends one span, one metric data point and one log record over OTLP/HTTP, then asserts the collector
accepted each one and wrote it to `data/traces.json`, `data/metrics.json` and `data/logs.json`.
Exits non-zero on any failure.

## Layout

```
docker-compose.yml           the instance
config/otelcol-contrib.yaml  collector config: receivers, processors, exporters, pipelines
scripts/smoke-test.sh        end-to-end verification
data/                        exporter output (gitignored)
```

The pipeline for each of traces, metrics and logs is `otlp → memory_limiter, batch → debug + file/<signal>`.
Each signal writes its own exporter file so the three pipelines never share a file handle.

## Pointing a real backend at it

The `file/*` exporters keep the instance self-contained. To send to a backend instead (Jaeger,
Prometheus, Grafana Tempo, an OTLP endpoint), add an exporter under `exporters:` in
[`config/otelcol-contrib.yaml`](config/otelcol-contrib.yaml) and list it in the relevant pipeline in
`service.pipelines`, then `docker compose restart otel-collector`.
