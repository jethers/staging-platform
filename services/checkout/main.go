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

// WalletResponse espelha a resposta do wallet (checkout → wallet → ledger).
type WalletResponse struct {
	Account      string  `json:"account"`
	Balance      float64 `json:"balance"`
	Currency     string  `json:"currency"`
	WalletStatus string  `json:"wallet_status"`
	Version      string  `json:"version"`
}

type CheckoutResponse struct {
	Account       string  `json:"account"`
	Amount        float64 `json:"amount"`
	Currency      string  `json:"currency"`
	Approved      bool    `json:"approved"`
	WalletStatus  string  `json:"wallet_status"`
	WalletVersion string  `json:"wallet_version"`
	Version       string  `json:"version"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

// version é injetada em tempo de build via ldflags: -X main.version=<value>
var version = "dev"

var walletURL string

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
	json.NewEncoder(w).Encode(HealthResponse{Status: "ok", Service: "checkout"})
}

func checkoutHandler(w http.ResponseWriter, r *http.Request) {
	account := r.PathValue("account")
	if account == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "account is required"})
		return
	}

	// Chama o wallet (que por sua vez chama o ledger)
	walletStart := time.Now()
	resp, err := http.Get(fmt.Sprintf("%s/wallet/%s", walletURL, account))
	walletLatency := time.Since(walletStart)

	if err != nil {
		log.Printf("upstream=wallet account=%s error=%v latency=%s", account, err, walletLatency)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "failed to reach wallet"})
		return
	}
	defer resp.Body.Close()

	log.Printf("upstream=wallet account=%s status=%d latency=%s", account, resp.StatusCode, walletLatency)

	if resp.StatusCode != http.StatusOK {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "wallet returned non-200"})
		return
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "failed to read wallet response"})
		return
	}

	var wallet WalletResponse
	if err := json.Unmarshal(body, &wallet); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "failed to parse wallet response"})
		return
	}

	// Regra de negócio simples: aprova a compra se há saldo e a carteira está ativa.
	amount := 100.0
	approved := wallet.WalletStatus == "active" && wallet.Balance >= amount

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(CheckoutResponse{
		Account:       wallet.Account,
		Amount:        amount,
		Currency:      wallet.Currency,
		Approved:      approved,
		WalletStatus:  wallet.WalletStatus,
		WalletVersion: wallet.Version,
		Version:       version,
	})
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	walletURL = os.Getenv("WALLET_URL")
	if walletURL == "" {
		walletURL = "http://wallet:8080"
	}

	log.SetFlags(log.Ldate | log.Ltime | log.LUTC)
	log.Printf("service=checkout version=%s starting on port=%s wallet_url=%s", version, port, walletURL)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", healthHandler)
	mux.HandleFunc("GET /checkout/{account}", checkoutHandler)

	handler := loggingMiddleware(mux)

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      handler,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("service=checkout error=%v", err)
	}
}
