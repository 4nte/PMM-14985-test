# Verify `VMPromDBSeriesReadPerQuery` telemetry (PMM-14985)

Bring up your own PMM (must include the new telemetry config from
`PMM-14985-add-promdb-telemetry`), enable promdb, and verify in the PMM UI.

> For a scripted variant with auto-assertions, see the [`automated-test`](../../tree/automated-test) branch.

### 1. Wire promdb into your PMM stack

Layer `docker-compose.promdb.yml` on top of your existing PMM compose file.
Run this from the current directory so `${PWD}/blocks` in the override
resolves to the TSDB blocks shipped alongside this file:

```sh
docker compose -f /path/to/your/pmm-compose.yml \
               -f docker-compose.promdb.yml up -d
```

This adds `VM_prometheusDataPath=/srv/prometheus/data` to the `pmm-server`
service and bind-mounts `./blocks` into that path.

### 2. Open the PMM UI

`https://<your-pmm>:8443` and log in.

### 3. Confirm the Prometheus-native data is queryable

In UI, **Explore → Metrics datasource**, time range **Last 8 hours**, run:

```promql
up
```

You should see many `up` series. Among them is `up{job="qa_promdb_synthetic", instance="qa"}` with hourly samples
across the last 6 hours: that's the Prometheus-native series read out of promdb.

### 4. Check the new telemetry counter

In the same Explore tab:

```promql
vm_promdb_series_read_per_query_count
```

Expected: a positive value, increasing as you re-run step 3.

### 5. Watch the reported average

```promql
sum(rate(vm_promdb_series_read_per_query_sum[5m]))
  / sum(rate(vm_promdb_series_read_per_query_count[5m]))
```

This is the same expression PMM ships as `vm_promdb_series_read_per_query_avg`
in the telemetry payload. We expect it to be non-zero value after querying `up`, this confirms that new telemetry is working as intended. 

---

### Regenerating the blocks

If queries return no data, the blocks have aged out of VM retention. Run from
this directory:

```sh
rm -rf blocks && mkdir blocks
NOW=$(date +%s)
{
  echo '# HELP up Prometheus-native sample planted under VM'\''s -prometheusDataPath'
  echo '# TYPE up gauge'
  for i in 6 5 4 3 2 1 0; do
    echo "up{job=\"qa_promdb_synthetic\",instance=\"qa\"} 1 $((NOW - i*3600)).000"
  done
  echo '# EOF'
} > synthetic.openmetrics
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" \
  --entrypoint promtool prom/prometheus:latest \
  tsdb create-blocks-from openmetrics /work/synthetic.openmetrics /work/blocks
rm synthetic.openmetrics
```
