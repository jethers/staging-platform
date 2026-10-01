# --- Build stage ---
FROM golang:1.26-alpine AS builder

WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o ledger .

# --- Final stage ---
FROM alpine:3.20

RUN addgroup -S app && adduser -S app -G app
WORKDIR /app
COPY --from=builder /app/ledger .
USER app

EXPOSE 8080
ENTRYPOINT ["./ledger"]
