package main

import (
	"encoding/json"
	"fmt"
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

type BalanceResponse struct {
	Account  string  `json:"account"`
	Balance  float64 `json:"balance"`
	Currency string  `json:"currency"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

// loggingMiddleware loga método, path, status code e latência de cada requisição.
func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		requestID := fmt.Sprintf("%x", rand.Int63())

		lrw := &loggingResponseWriter{ResponseWriter: w, statusCode: http.StatusOK}
		next.ServeHTTP(lrw, r)

		log.Printf("request_id=%s method=%s path=%s status=%d latency=%s",
			requestID, r.Method, r.URL.Path, lrw.statusCode, time.Since(start))
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
	json.NewEncoder(w).Encode(HealthResponse{Status: "ok", Service: "ledger"})
}

func balanceHandler(w http.ResponseWriter, r *http.Request) {
	account := r.PathValue("account")
	if account == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "account is required"})
		return
	}

	// Saldo mockado: usa o hash do account para gerar um valor determinístico
	var sum int
	for _, c := range account {
		sum += int(c)
	}
	balance := float64(1000+(sum%9000)) + 0.50

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(BalanceResponse{
		Account:  account,
		Balance:  balance,
		Currency: "BRL",
	})
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.SetFlags(log.Ldate | log.Ltime | log.LUTC)
	log.Printf("service=ledger starting on port=%s", port)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", healthHandler)
	mux.HandleFunc("GET /balance/{account}", balanceHandler)

	handler := loggingMiddleware(mux)

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      handler,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("service=ledger error=%v", err)
	}
}
