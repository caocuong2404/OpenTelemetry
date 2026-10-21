#!/usr/bin/env bash
#
# Smoke test for the local grafana/otel-lgtm instance.
#
# Sends one trace, one metric and one log record over OTLP/HTTP (JSON), then
# asserts each one is queryable from the backend that stores it: the trace in
# Tempo, the metric in Prometheus, the log in Loki. Also checks the Grafana UI
# is up, since that is the point of this stack.
#
# Usage: ./scripts/smoke-test.sh
#   OTEL_LGTM_OTLP_URL       OTLP/HTTP endpoint   (default http://localhost:4318)
#   OTEL_LGTM_GRAFANA_URL    Grafana UI           (default http://localhost:3000)
#   OTEL_LGTM_PROMETHEUS_URL Prometheus API       (default http://localhost:9090)
#   OTEL_LGTM_TEMPO_URL      Tempo API            (default http://localhost:3200)
#   OTEL_LGTM_LOKI_URL       Loki API             (default http://localhost:3100)
#   QUERY_TIMEOUT_SECONDS    how long to wait for a signal to land (default 30)

set -euo pipefail

OTLP_URL="${OTEL_LGTM_OTLP_URL:-http://localhost:4318}"
GRAFANA_URL="${OTEL_LGTM_GRAFANA_URL:-http://localhost:3000}"
PROMETHEUS_URL="${OTEL_LGTM_PROMETHEUS_URL:-http://localhost:9090}"
TEMPO_URL="${OTEL_LGTM_TEMPO_URL:-http://localhost:3200}"
LOKI_URL="${OTEL_LGTM_LOKI_URL:-http://localhost:3100}"
QUERY_TIMEOUT_SECONDS="${QUERY_TIMEOUT_SECONDS:-30}"

RESPONSE_FILE="${TMPDIR:-/tmp}/otel-smoke-response.$$"
trap 'rm -f "$RESPONSE_FILE"' EXIT

rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

RUN_ID="${RUN_ID:-$(rand_hex 8)}"
TRACE_ID="$(rand_hex 16)"
SPAN_ID="$(rand_hex 8)"
NOW_NS="$(($(date +%s) * 1000000000))"
START_NS="$((NOW_NS - 5000000000))"

# Shared across the three payloads so every stored record is traceable to
# this run.
RESOURCE_ATTRIBUTES="{
        \"key\": \"service.name\",
        \"value\": {\"stringValue\": \"smoke-test\"}
      },
      {
        \"key\": \"smoke.run.id\",
        \"value\": {\"stringValue\": \"$RUN_ID\"}
      }"

RUN_ATTRIBUTE="{\"key\": \"smoke.run.id\", \"value\": {\"stringValue\": \"$RUN_ID\"}}"

FAILURES=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

check() {
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# Poll a backend until it answers true, so a slow first write does not flake
# the test. Takes a description and a probe command.
wait_for() {
  local desc="$1" deadline=$(($(date +%s) + QUERY_TIMEOUT_SECONDS)); shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if "$@"; then
      pass "$desc"
      return 0
    fi
    sleep 0.5
  done
  fail "$desc (not queryable within ${QUERY_TIMEOUT_SECONDS}s)"
  return 1
}

post_json() {
  local path="$1" body="$2"
  curl --silent --show-error \
    --header 'Content-Type: application/json' \
    --output "$RESPONSE_FILE" \
    --write-out '%{http_code}' \
    --data "$body" \
    "${OTLP_URL}${path}"
}

trace_in_tempo() {
  curl --silent --fail "${TEMPO_URL}/api/traces/${TRACE_ID}" | grep -q "$RUN_ID"
}

metric_in_prometheus() {
  # Metric names are translated on ingest, so match on the run marker label
  # rather than assuming an exact series name.
  curl --silent --fail -G "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query={smoke_run_id=\"${RUN_ID}\"}" | grep -q "$RUN_ID"
}

log_in_loki() {
  curl --silent --fail -G "${LOKI_URL}/loki/api/v1/query_range" \
    --data-urlencode "query={service_name=\"smoke-test\"} |= \"${RUN_ID}\"" \
    --data-urlencode "limit=100" | grep -q "$RUN_ID"
}

echo "smoke test run id: $RUN_ID"
echo "otlp endpoint:     $OTLP_URL"
echo

echo "1. backends are up"
check "Grafana web UI answers" \
  curl --silent --fail --output /dev/null "${GRAFANA_URL}/api/health"
check "Prometheus answers" \
  curl --silent --fail --output /dev/null "${PROMETHEUS_URL}/-/ready"
check "Tempo answers" \
  curl --silent --fail --output /dev/null "${TEMPO_URL}/ready"
check "Loki answers" \
  curl --silent --fail --output /dev/null "${LOKI_URL}/ready"

echo
echo "2. OTLP/HTTP accepts telemetry"

trace_body="$(cat <<EOF
{
  "resourceSpans": [{
    "resource": {"attributes": [$RESOURCE_ATTRIBUTES]},
    "scopeSpans": [{
      "scope": {"name": "smoke-test"},
      "spans": [{
        "traceId": "$TRACE_ID",
        "spanId": "$SPAN_ID",
        "name": "smoke-test-span",
        "kind": 2,
        "startTimeUnixNano": "$START_NS",
        "endTimeUnixNano": "$NOW_NS",
        "attributes": [$RUN_ATTRIBUTE],
        "status": {"code": 1}
      }]
    }]
  }]
}
EOF
)"

metric_body="$(cat <<EOF
{
  "resourceMetrics": [{
    "resource": {"attributes": [$RESOURCE_ATTRIBUTES]},
    "scopeMetrics": [{
      "scope": {"name": "smoke-test"},
      "metrics": [{
        "name": "smoke.test.counter",
        "unit": "1",
        "sum": {
          "aggregationTemporality": 2,
          "isMonotonic": true,
          "dataPoints": [{
            "asInt": "1",
            "startTimeUnixNano": "$START_NS",
            "timeUnixNano": "$NOW_NS",
            "attributes": [$RUN_ATTRIBUTE]
          }]
        }
      }]
    }]
  }]
}
EOF
)"

log_body="$(cat <<EOF
{
  "resourceLogs": [{
    "resource": {"attributes": [$RESOURCE_ATTRIBUTES]},
    "scopeLogs": [{
      "scope": {"name": "smoke-test"},
      "logRecords": [{
        "timeUnixNano": "$NOW_NS",
        "severityNumber": 9,
        "severityText": "INFO",
        "body": {"stringValue": "smoke-test-log $RUN_ID"},
        "attributes": [$RUN_ATTRIBUTE]
      }]
    }]
  }]
}
EOF
)"

for signal in traces metrics logs; do
  case "$signal" in
    traces)  path="/v1/traces";  body="$trace_body" ;;
    metrics) path="/v1/metrics"; body="$metric_body" ;;
    logs)    path="/v1/logs";    body="$log_body" ;;
  esac

  code="$(post_json "$path" "$body")" || code="curl-error"
  if [ "$code" = "200" ]; then
    pass "POST $path -> 200"
  else
    fail "POST $path -> expected 200, got ${code}"
    [ -s "$RESPONSE_FILE" ] && sed 's/^/       /' "$RESPONSE_FILE"
  fi
done

echo
echo "3. each signal is queryable from its backend"
wait_for "Tempo returns the trace ($TRACE_ID)" trace_in_tempo
wait_for "Prometheus returns the metric" metric_in_prometheus
wait_for "Loki returns the log record" log_in_loki

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "smoke test: PASS"
  echo "see the data in Grafana: ${GRAFANA_URL} (admin/admin)"
  exit 0
fi
echo "smoke test: FAIL ($FAILURES check(s) failed)"
exit 1
