#!/bin/bash
# Renders fixtures/synthetic.openmetrics.tmpl with timestamps spaced across
# the last 6 hours, then runs `promtool tsdb create-blocks-from openmetrics`
# inside a transient prom/prometheus container to materialize TSDB blocks
# under blocks/ (consumed by the pmm-server bind mount in docker-compose.qa.yml).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPL="${HERE}/fixtures/synthetic.openmetrics.tmpl"
RENDERED="${HERE}/fixtures/synthetic.openmetrics"
BLOCKS_DIR="${HERE}/blocks"
PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE:-prom/prometheus:latest}"

if [[ ! -f "${TMPL}" ]]; then
  echo "ERROR: template not found at ${TMPL}" >&2
  exit 1
fi

NOW="$(date +%s)"
SED_ARGS=()
for i in 0 1 2 3 4 5 6; do
  HOURS_AGO=$((6 - i))
  TS=$((NOW - HOURS_AGO * 3600))
  SED_ARGS+=(-e "s/__TS_${i}__/${TS}.000/")
done

sed "${SED_ARGS[@]}" "${TMPL}" > "${RENDERED}"
echo "Rendered ${RENDERED} (samples spanning last 6h, NOW=${NOW})"

rm -rf "${BLOCKS_DIR}"
mkdir -p "${BLOCKS_DIR}"

echo "Running promtool inside ${PROMETHEUS_IMAGE} ..."
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${HERE}:/work" \
  --entrypoint promtool \
  "${PROMETHEUS_IMAGE}" \
  tsdb create-blocks-from openmetrics \
    /work/fixtures/synthetic.openmetrics \
    /work/blocks

echo "Generated blocks under ${BLOCKS_DIR}:"
find "${BLOCKS_DIR}" -mindepth 1 -maxdepth 2 -printf '  %p\n'
