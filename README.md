# PMM-14985 QA harness

How to run the test suite.

## Prerequisites

- Docker (with the `compose` subcommand)
- `jq`, `curl`, `bash`, `git`
- A local clone of [percona/pmm](https://github.com/percona/pmm) on the
  `v3` branch
- Internet access on first run (to pull `percona/pmm-server:3` and
  `prom/prometheus:latest`)

## Setup

This repo must be cloned **inside the PMM repo root**, as a sibling of
`managed/` and `docker-compose.yml`:

```sh
cd <pmm-repo-root>     # e.g. ~/git/percona/pmm
git clone https://github.com/4nte/PMM-14985-promdb-telemetry-test.git
```

Resulting layout:

```
<pmm-repo-root>/
├── managed/
├── docker-compose.yml
└── PMM-14985-promdb-telemetry-test/   # this repo
```

## Quick start

```sh
cd <pmm-repo-root>/PMM-14985-promdb-telemetry-test
./run-test.sh
```

End-to-end runtime is ~3-4 minutes. On success the script prints
`SUCCESS`. The stack is left running so you can poke around — open
`https://127.0.0.1:8443` (admin / admin). When done:

```sh
./run-test.sh --down
```

Override PMM API credentials with `PMM_AUTH=user:pass` if your local
image differs from `admin:admin`.

## Modes

| Invocation | What it does |
|---|---|
| `./run-test.sh` | Positive run. Asserts the captured value is > 0. |
| `UNSET_PROMDB=1 ./run-test.sh` | Negative run. Asserts the captured value is exactly 0. |
| `./run-test.sh --upstream check-dev` | Sends telemetry to `https://check-dev.percona.com` instead of the local receiver. |
| `./run-test.sh --down` | Tears the stack down and removes generated artifacts. |
