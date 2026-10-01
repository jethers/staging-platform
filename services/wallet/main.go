package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"time"
)

type HealthResponse struct {
	Status  string `json:"status"`
	Service string `json:"service"`
}

type LedgerBalance struct {
	Account  string  `json:"account"`
	Balance  float64 `json:"balance"`
	Currency string  `json:"currency"`
}

type WalletResponse struct {
	Account      string  `json:"account"`
	Balance      float64 `json:"balance"`
	Currency     string  `json:"currency"`
	WalletStatus string  `json:"wallet_status"`
	Version      string  `json:"version"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

// version é injetada em tempo de build via ldflags: -X main.version=<value>
var version = "dev"

var ledgerURL string

// loggingMiddleware loga método, path, status code e latência de cada requisição.
func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		requestID := fmt.Sprintf("%x", rand.Int63())

		lrw := &loggingResponseWriter{ResponseWriter: w, statusCode: http.StatusOK}
		next.ServeHTTP(lrw, r)

		log.Printf("request_id=%s version=%s method=%s path=%s status=%d latency=%s",
			requestID, version, r.Method, r.URL.Path, lrw.statusCode, time.Since(start))
	})
}

type loggingResponseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (lrw *loggingResponseWriter) WriteHeader(code int) {
	lrw.statusCode = code
	lrw.ResponseWriter.WriteHeader(code)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(HealthResponse{Status: "ok", Service: "wallet"})
}

func walletHandler(w http.ResponseWriter, r *http.Request) {
	account := r.PathValue("account")
	if account == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "account is required"})
		return
	}

	// Chama o ledger
	ledgerStart := time.Now()
	resp, err := http.Get(fmt.Sprintf("%s/balance/%s", ledgerURL, account))
	ledgerLatency := time.Since(ledgerStart)

	if err != nil {
		log.Printf("upstream=ledger account=%s error=%v latency=%s", account, err, ledgerLatency)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "failed to reach ledger"})
		return
	}
	defer resp.Body.Close()

	log.Printf("upstream=ledger account=%s status=%d latency=%s", account, resp.StatusCode, ledgerLatency)

	if resp.StatusCode != http.StatusOK {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "ledger returned non-200"})
		return
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "failed to read ledger response"})
		return
	}

	var balance LedgerBalance
	if err := json.Unmarshal(body, &balance); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "failed to parse ledger response"})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(WalletResponse{
		Account:      balance.Account,
		Balance:      balance.Balance,
		Currency:     balance.Currency,
		WalletStatus: "active",
		Version:      version,
	})
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	ledgerURL = os.Getenv("LEDGER_URL")
	if ledgerURL == "" {
		ledgerURL = "http://ledger:8080"
	}

	log.SetFlags(log.Ldate | log.Ltime | log.LUTC)
	log.Printf("service=wallet version=%s starting on port=%s ledger_url=%s", version, port, ledgerURL)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", healthHandler)
	mux.HandleFunc("GET /wallet/{account}", walletHandler)

	handler := loggingMiddleware(mux)

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      handler,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("service=wallet error=%v", err)
	}
}
