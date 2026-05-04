#!/bin/bash
# QA verification of the VMPromDBSeriesReadPerQuery telemetry entry at
# managed/services/telemetry/config.default.yml:1133-1141. See README.md for
# background. This script is the single entry point QA should invoke.
#
# Modes:
#   ./run-test.sh                       # default: positive control via local fake receiver
#   ./run-test.sh --upstream check-dev  # route telemetry to https://check-dev.percona.com
#                                       # (assertion delegated to Percona-side tooling)
#   UNSET_PROMDB=1 ./run-test.sh        # negative control: do NOT activate promdb;
#                                       # telemetry should report 0
#   ./run-test.sh --down                # tear the stack down and exit
#
# Production endpoint https://check.percona.com is rejected as a safety guard.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURES_DIR="${HERE}/captures"
COMPOSE_BASE=( -f "${HERE}/docker-compose.qa.yml" )
COMPOSE_PROMDB=( -f "${HERE}/docker-compose.qa.promdb.yml" )
PMM_HOST_PORT="${PMM_PORT_HTTPS:-8443}"
PMM_URL="https://127.0.0.1:${PMM_HOST_PORT}"
PMM_AUTH="${PMM_AUTH:-admin:admin}"
RECEIVER_URL="http://127.0.0.1:18080"

UPSTREAM_MODE="local"          # "local" | "check-dev"
UNSET_PROMDB="${UNSET_PROMDB:-0}"
TEAR_DOWN_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --down)
      TEAR_DOWN_ONLY=1; shift ;;
    --upstream)
      UPSTREAM_MODE="${2:-}"; shift 2 ;;
    --upstream=*)
      UPSTREAM_MODE="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "${UPSTREAM_MODE}" in
  local)     QA_PROMDB_PLATFORM_ADDRESS="http://qa-receiver:8080" ;;
  check-dev) QA_PROMDB_PLATFORM_ADDRESS="https://check-dev.percona.com" ;;
  *) echo "ERROR: --upstream must be 'local' or 'check-dev', got '${UPSTREAM_MODE}'" >&2; exit 2 ;;
esac

if [[ "${QA_PROMDB_PLATFORM_ADDRESS}" == *"check.percona.com"* ]] \
   && [[ "${QA_PROMDB_PLATFORM_ADDRESS}" != *"check-dev.percona.com"* ]]; then
  echo "ERROR: refusing to use production telemetry endpoint" >&2; exit 3
fi
export QA_PROMDB_PLATFORM_ADDRESS

compose_args() {
  local args=( "${COMPOSE_BASE[@]}" )
  if [[ "${UNSET_PROMDB}" != "1" ]]; then
    args+=( "${COMPOSE_PROMDB[@]}" )
  fi
  printf '%s\n' "${args[@]}"
}
mapfile -t COMPOSE_FLAGS < <(compose_args)

require_cmd() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 4; }; }
require_cmd docker
require_cmd jq
require_cmd curl

# This suite relies on a sibling path resolving to the PMM repo's telemetry
# config: ../managed/services/telemetry/config.default.yml gets bind-mounted
# into pmm-server. Bail loudly if the parent directory is not the PMM repo.
if [[ ! -f "${HERE}/../managed/services/telemetry/config.default.yml" ]]; then
  cat >&2 <<EOF
ERROR: expected the PMM telemetry config at
       ${HERE}/../managed/services/telemetry/config.default.yml
       This suite must be cloned at <pmm-repo-root>/PMM-14985-promdb-telemetry-test/
       and run from that location. See README.md "Setup".
EOF
  exit 4
fi

step() { printf '\n=== %s ===\n' "$*"; }

teardown() {
  step "tearing down qa stack"
  docker compose "${COMPOSE_BASE[@]}" "${COMPOSE_PROMDB[@]}" down -v --remove-orphans || true
  rm -rf "${HERE}/blocks" "${HERE}/fixtures/synthetic.openmetrics" "${CAPTURES_DIR}"
}

if [[ "${TEAR_DOWN_ONLY}" == "1" ]]; then
  teardown; exit 0
fi

step "config summary"
cat <<EOF
mode:              $([[ "${UNSET_PROMDB}" == "1" ]] && echo "NEGATIVE control (promdb off)" || echo "POSITIVE control (promdb on)")
upstream:          ${UPSTREAM_MODE} -> ${QA_PROMDB_PLATFORM_ADDRESS}
pmm-server image:  ${PMM_SERVER_IMAGE:-percona/pmm-server:3}
pmm-server URL:    ${PMM_URL}
receiver URL:      ${RECEIVER_URL}  $([[ "${UPSTREAM_MODE}" == "check-dev" ]] && echo "(receiver irrelevant in check-dev mode)" || echo "")
captures dir:      ${CAPTURES_DIR}
EOF

step "step 1/12 - wipe prior state"
docker compose "${COMPOSE_BASE[@]}" "${COMPOSE_PROMDB[@]}" down -v --remove-orphans || true
rm -rf "${CAPTURES_DIR}"
mkdir -p "${CAPTURES_DIR}"
# Receiver runs as the distroless 'nonroot' user (UID 65532); the host bind
# mount is owned by the invoking user, so loosen perms so the container can
# write capture files.
chmod 0777 "${CAPTURES_DIR}"

if [[ "${UNSET_PROMDB}" == "1" ]]; then
  step "steps 2-3/12 - SKIPPED (negative-control mode plants no blocks)"
else
  step "step 2-3/12 - render OpenMetrics fixture & build TSDB blocks"
  bash "${HERE}/generate-blocks.sh"
fi

step "step 4/12 - build qa-receiver image"
docker compose "${COMPOSE_FLAGS[@]}" build qa-receiver

step "step 5/12 - bring up stack"
docker compose "${COMPOSE_FLAGS[@]}" up -d

step "step 6/12 - wait for pmm-server /v1/server/readyz & qa-receiver /healthz"
DEADLINE=$(( $(date +%s) + 240 ))
until curl -skf "${PMM_URL}/v1/server/readyz" >/dev/null 2>&1; do
  [[ $(date +%s) -gt ${DEADLINE} ]] && { echo "pmm-server never became ready"; docker compose "${COMPOSE_FLAGS[@]}" logs --tail=200 pmm-server; exit 5; }
  echo "  waiting for pmm-server ..."
  sleep 5
done
echo "pmm-server ready"
until curl -sf "${RECEIVER_URL}/healthz" >/dev/null 2>&1; do
  [[ $(date +%s) -gt ${DEADLINE} ]] && { echo "qa-receiver never became ready"; docker compose "${COMPOSE_FLAGS[@]}" logs --tail=100 qa-receiver; exit 5; }
  echo "  waiting for qa-receiver ..."
  sleep 2
done
echo "qa-receiver ready"

if [[ "${UNSET_PROMDB}" != "1" ]]; then
  step "step 7/12 - confirm VM opened promdb at -prometheusDataPath"
  PROMDB_DEADLINE=$(( $(date +%s) + 60 ))
  until docker exec qa-pmm-server cat /srv/logs/victoriametrics.log 2>/dev/null \
        | grep -q 'successfully opened historical Prometheus data'; do
    [[ $(date +%s) -gt ${PROMDB_DEADLINE} ]] && {
      echo "FAIL: did not see 'successfully opened historical Prometheus data' in VM log"
      echo "(this means VM_prometheusDataPath did not propagate, or VM rejected the path)"
      docker exec qa-pmm-server tail -n 60 /srv/logs/victoriametrics.log || true
      exit 6
    }
    echo "  waiting for VM to open promdb ..."
    sleep 2
  done
  docker exec qa-pmm-server grep -m1 'successfully opened historical Prometheus data' /srv/logs/victoriametrics.log
else
  step "step 7/12 - SKIPPED (negative control: promdb intentionally not activated)"
fi

step "step 8/12 - drive promdb traffic spread across multiple self-scrape intervals"
# The telemetry query uses sum(rate(_sum[24h])) / sum(rate(_count[24h])).
# rate() needs the counter to *increase across at least two scraped samples*,
# not just bump once. VM scrapes its own /metrics every 5s (per
# /etc/victoriametrics-promscrape.yml), so we issue queries gradually over
# ~75s with a brief settling sleep at the start (so the first scrape sees a
# low baseline rather than the post-burst value).
START_TS=$(date -d '8 hours ago' +%s)
END_TS=$(date +%s)
echo "  letting VM capture a low-_sum baseline (10s) ..."
sleep 10
echo "  issuing 30 authed range queries over ~75s (1 every 2.5s) ..."
for i in $(seq 1 30); do
  curl -sk -u "${PMM_AUTH}" -G "${PMM_URL}/prometheus/api/v1/query_range" \
    --data-urlencode "query=up" \
    --data-urlencode "start=${START_TS}" \
    --data-urlencode "end=${END_TS}" \
    --data-urlencode "step=300" >/dev/null
  sleep 2.5
done
echo "  waiting 20s for the final scrape samples to land ..."
sleep 20

step "step 9/12 - read vm_promdb_series_read_per_query_{count,sum} from VM"
COUNT_RAW="$(curl -sk -u "${PMM_AUTH}" -G "${PMM_URL}/prometheus/api/v1/query" \
  --data-urlencode 'query=sum(vm_promdb_series_read_per_query_count)' \
  | jq -r '.data.result[0].value[1] // "0"')"
SUM_RAW="$(curl -sk -u "${PMM_AUTH}" -G "${PMM_URL}/prometheus/api/v1/query" \
  --data-urlencode 'query=sum(vm_promdb_series_read_per_query_sum)' \
  | jq -r '.data.result[0].value[1] // "0"')"
echo "vm_promdb_series_read_per_query_count = ${COUNT_RAW}"
echo "vm_promdb_series_read_per_query_sum   = ${SUM_RAW}"
if [[ "${UNSET_PROMDB}" != "1" ]]; then
  awk -v s="${SUM_RAW}" 'BEGIN{ exit !(s+0 > 0) }' || {
    echo "FAIL: _sum should be > 0 in positive-control mode but is ${SUM_RAW}"
    echo "in-memory counters (direct from VM, bypassing nginx):"
    docker exec qa-pmm-server curl -s http://127.0.0.1:9090/prometheus/metrics \
      | grep -E '^vm_promdb_series_read_per_query' || true
    exit 7
  }
fi

step "step 10/12 - wait for telemetry tick (interval = 60s)"
sleep 90

if [[ "${UPSTREAM_MODE}" == "check-dev" ]]; then
  step "steps 11-12/12 - SKIPPED in check-dev mode"
  echo "telemetry was sent to ${QA_PROMDB_PLATFORM_ADDRESS} - inspect via Percona internal tooling"
  echo
  echo "SUCCESS (VM-side checks only). Run './run-test.sh --down' when finished."
  exit 0
fi

step "step 11/12 - inspect receiver captures"
shopt -s nullglob
CAPTURES=( "${CAPTURES_DIR}"/report-*.json )
shopt -u nullglob
if [[ ${#CAPTURES[@]} -eq 0 ]]; then
  echo "FAIL: no captures in ${CAPTURES_DIR}"
  docker compose "${COMPOSE_FLAGS[@]}" logs --tail=100 pmm-server | grep -i telemetry || true
  docker compose "${COMPOSE_FLAGS[@]}" logs --tail=50 qa-receiver || true
  exit 8
fi
echo "captured ${#CAPTURES[@]} report(s):"
for f in "${CAPTURES[@]}"; do printf '  %s\n' "$f"; done

LATEST_CAPTURE="${CAPTURES[-1]}"
AVG_VALUE="$(jq -r '
  ( .reports // [] )[]
  | ( .metrics // [] )[]
  | select(.key == "vm_promdb_series_read_per_query_avg")
  | .value
' "${LATEST_CAPTURE}" | tail -n1)"
echo "vm_promdb_series_read_per_query_avg in latest capture: ${AVG_VALUE:-<missing>}"

step "step 12/12 - assert on captured value"
if [[ -z "${AVG_VALUE}" || "${AVG_VALUE}" == "null" ]]; then
  echo "FAIL: vm_promdb_series_read_per_query_avg key missing from capture"
  echo "raw capture:"; jq . "${LATEST_CAPTURE}"
  exit 9
fi
if [[ "${UNSET_PROMDB}" == "1" ]]; then
  awk -v v="${AVG_VALUE}" 'BEGIN{ exit !(v+0 == 0) }' || {
    echo "FAIL (negative control): expected 0, got ${AVG_VALUE}"
    exit 10
  }
  echo "PASS (negative control): avg = 0 as expected"
else
  awk -v v="${AVG_VALUE}" 'BEGIN{ exit !(v+0 > 0) }' || {
    echo "FAIL (positive control): expected > 0, got ${AVG_VALUE}"
    exit 11
  }
  echo "PASS (positive control): avg = ${AVG_VALUE} (> 0)"
fi

cat <<EOF

SUCCESS
  mode:           $([[ "${UNSET_PROMDB}" == "1" ]] && echo "NEGATIVE control" || echo "POSITIVE control")
  captured value: ${AVG_VALUE}
  capture file:   ${LATEST_CAPTURE}
  pmm-server UI:  ${PMM_URL} (admin/admin)

Stack left running. Run './run-test.sh --down' when finished.
EOF
