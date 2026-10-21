#!/usr/bin/env bash
#
# Smoke test for the local OpenTelemetry Collector instance.
#
# Sends one trace, one metric and one log record over OTLP/HTTP (JSON), then
# asserts that the collector accepted each one and exported it to the matching
# file under ./data.
#
# Usage: ./scripts/smoke-test.sh
#   OTEL_COLLECTOR_OTLP_URL         OTLP/HTTP endpoint      (default http://localhost:4318)
#   OTEL_COLLECTOR_HEALTH_URL       health_check endpoint   (default http://localhost:13133/)
#   OTEL_COLLECTOR_SELF_METRICS_URL self-metrics endpoint   (default http://localhost:8888/metrics)
#   OTEL_COLLECTOR_DATA_DIR         exporter output dir     (default ./data)
#   EXPORT_TIMEOUT_SECONDS          how long to wait for export (default 15)

set -euo pipefail

OTLP_URL="${OTEL_COLLECTOR_OTLP_URL:-http://localhost:4318}"
HEALTH_URL="${OTEL_COLLECTOR_HEALTH_URL:-http://localhost:13133/}"
SELF_METRICS_URL="${OTEL_COLLECTOR_SELF_METRICS_URL:-http://localhost:8888/metrics}"
DATA_DIR="${OTEL_COLLECTOR_DATA_DIR:-$(cd "$(dirname "$0")/.." && pwd)/data}"
EXPORT_TIMEOUT_SECONDS="${EXPORT_TIMEOUT_SECONDS:-15}"

RESPONSE_FILE="${TMPDIR:-/tmp}/otel-smoke-response.$$"
trap 'rm -f "$RESPONSE_FILE"' EXIT

rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

RUN_ID="${RUN_ID:-$(rand_hex 8)}"
TRACE_ID="$(rand_hex 16)"
SPAN_ID="$(rand_hex 8)"
NOW_NS="$(($(date +%s) * 1000000000))"
START_NS="$((NOW_NS - 5000000000))"

# Shared across the three payloads so every exported record is traceable to
# this run.
RESOURCE_ATTRIBUTES="{
        \"key\": \"service.name\",
        \"value\": {\"stringValue\": \"smoke-test\"}
      },
      {
        \"key\": \"smoke.run.id\",
        \"value\": {\"stringValue\": \"$RUN_ID\"}
      }"

FAILURES=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

check() {
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
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

# The batch processor flushes every 200ms and the file exporter every 1s, so
# export is expected within a second or two; poll rather than sleep a fixed
# interval so a slow host does not flake the test.
wait_for_export() {
  local file="$1" deadline=$(($(date +%s) + EXPORT_TIMEOUT_SECONDS))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$file" ] && grep -q "$RUN_ID" "$file"; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

echo "smoke test run id: $RUN_ID"
echo "otlp endpoint:     $OTLP_URL"
echo "data dir:          $DATA_DIR"
echo

echo "1. collector is up"
check "health_check extension answers" \
  curl --silent --fail --output /dev/null "$HEALTH_URL"
check "self-metrics endpoint answers" \
  curl --silent --fail --output /dev/null "$SELF_METRICS_URL"

echo
echo "2. OTLP/HTTP accepts telemetry and the exporters write it out"

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
            "attributes": [{"key": "smoke.run.id", "value": {"stringValue": "$RUN_ID"}}]
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
        "attributes": [{"key": "smoke.run.id", "value": {"stringValue": "$RUN_ID"}}]
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

  if wait_for_export "$DATA_DIR/$signal.json"; then
    pass "$signal.json contains the run marker"
  else
    fail "$signal.json does not contain the run marker within ${EXPORT_TIMEOUT_SECONDS}s"
  fi
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "smoke test: PASS"
  exit 0
fi
echo "smoke test: FAIL ($FAILURES check(s) failed)"
exit 1
