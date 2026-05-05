# Verify `VMPromDBSeriesReadPerQuery` telemetry (PMM-14985)

Run from this directory. Requires Docker, `curl`, `jq`, and outbound HTTPS to
`check-dev.percona.com`. Must be cloned at `<pmm-root>/PMM-14985-promdb-telemetry-test/minimal/`.

### 1. Generate TSDB blocks

```sh
mkdir -p blocks && rm -rf blocks/*
NOW=$(date +%s)
{
  echo '# HELP up synthetic'
  echo '# TYPE up gauge'
  for i in 6 5 4 3 2 1 0; do
    echo "up{job=\"qa_promdb_synthetic\",instance=\"qa\"} 1 $((NOW - i*3600)).000"
  done
  echo '# EOF'
} > synthetic.openmetrics
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" \
  --entrypoint promtool prom/prometheus:latest \
  tsdb create-blocks-from openmetrics /work/synthetic.openmetrics /work/blocks
```

### 2. Start the stack

```sh
docker compose up -d
until curl -skf https://127.0.0.1:8443/v1/server/readyz >/dev/null; do sleep 5; done && echo READY
```

### 3. Confirm VM opened promdb

```sh
docker exec qa-pmm-server-minimal grep \
  'successfully opened historical Prometheus data' /srv/logs/victoriametrics.log
```

Expect one matching line.

### 4. Drive promdb traffic

```sh
START=$(date -d '8 hours ago' +%s); END=$(date +%s)
for i in $(seq 1 30); do
  curl -sk -u admin:admin -G https://127.0.0.1:8443/prometheus/api/v1/query_range \
    --data-urlencode 'query=up' \
    --data-urlencode "start=$START" --data-urlencode "end=$END" \
    --data-urlencode 'step=300' >/dev/null
  sleep 2.5
done
```

### 5. Check VM counters

```sh
docker exec qa-pmm-server-minimal curl -s \
  'http://127.0.0.1:9090/prometheus/api/v1/query?query=vm_promdb_series_read_per_query_count' \
  | jq '.data.result[].value[1]'
```

Expect a positive integer.

### 6. Wait for telemetry tick

```sh
sleep 90
```

### 7. Confirm report sent

```sh
docker logs qa-pmm-server-minimal 2>&1 | grep -iE 'telemetry|GenericReport'
```

### 8. Inspect payload

Look up the latest report from this PMM instance ID in the check-dev portal.
`vm_promdb_series_read_per_query_avg` should be a positive number.

### Cleanup

```sh
docker compose down -v
rm -rf blocks synthetic.openmetrics
```
