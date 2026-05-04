// Fake Percona Platform telemetry receiver for QA verification of the
// VMPromDBSeriesReadPerQuery telemetry entry. Captures every
// POST /v1/telemetry/GenericReport body to /captures/<unix-nano>.json
// and replies 200 OK. Health check at /healthz.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

const captureDir = "/captures"

func main() {
	if err := os.MkdirAll(captureDir, 0o755); err != nil {
		log.Fatalf("mkdir %s: %v", captureDir, err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/v1/telemetry/GenericReport", handleReport)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("unhandled %s %s", r.Method, r.URL.Path)
		w.WriteHeader(http.StatusNotFound)
	})

	addr := ":8080"
	log.Printf("qa-receiver listening on %s, captures -> %s", addr, captureDir)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func handleReport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("read body: %v", err)
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	name := filepath.Join(captureDir, fmt.Sprintf("report-%d.json", time.Now().UnixNano()))
	if err := os.WriteFile(name, body, 0o644); err != nil {
		log.Printf("write %s: %v", name, err)
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	log.Printf("captured %d bytes -> %s", len(body), name)

	if hit, value := findPromDBMetric(body); hit {
		log.Printf("HIT vm_promdb_series_read_per_query_avg=%s", value)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{}`))
}

func findPromDBMetric(body []byte) (bool, string) {
	var envelope struct {
		Reports []struct {
			Metrics []struct {
				Key   string `json:"key"`
				Value string `json:"value"`
			} `json:"metrics"`
		} `json:"reports"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return false, ""
	}
	for _, r := range envelope.Reports {
		for _, m := range r.Metrics {
			if m.Key == "vm_promdb_series_read_per_query_avg" {
				return true, m.Value
			}
		}
	}
	return false, ""
}
