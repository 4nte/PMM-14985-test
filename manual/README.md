# Manual telemetry verification (PMM-14985)

Bring up your own PMM (must include the new telemetry config from
`PMM-14985-add-promdb-telemetry`), enable promdb, and verify in the PMM UI.

### 1. Wire promdb into your PMM stack

Layer `docker-compose.promdb.yml` on top of your existing PMM compose file:

```sh
docker compose -f /path/to/your/pmm-compose.yml \
               -f docker-compose.promdb.yml up -d
```

This adds `VM_prometheusDataPath=/srv/prometheus/data` to the `pmm-server`
service and bind-mounts `./blocks` into that path.

### 2. Open the PMM UI

`https://<your-pmm>:8443` and log in.

### 3. Confirm the synthetic data is queryable

**Explore → Metrics datasource**, time range **Last 8 hours**, run:

```promql
up{job="qa_promdb_synthetic"}
```

You should see 7 data points (one per hour over the last 6 hours). Re-run a
few times over ~1 minute so VM's self-scrape captures multiple samples.

### 4. Check the new telemetry counter

In the same Explore tab:

```promql
vm_promdb_series_read_per_query_count
```

Expected: a positive value, increasing as you re-run step 3.

### 5. (Optional) Watch the reported average

```promql
sum(rate(vm_promdb_series_read_per_query_sum[5m]))
  / sum(rate(vm_promdb_series_read_per_query_count[5m]))
```

This is the same expression PMM ships as `vm_promdb_series_read_per_query_avg`
in the telemetry payload.

---

### Regenerating the blocks

If queries return no data, the blocks have aged out of VM retention. Run from
this directory:

```sh
rm -rf blocks && mkdir blocks
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
rm synthetic.openmetrics
```
