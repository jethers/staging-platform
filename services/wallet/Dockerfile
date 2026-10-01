# --- Build stage ---
FROM golang:1.26-alpine AS builder

# VERSION é injetado no build e compilado no binário via ldflags
ARG VERSION=dev
WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-X main.version=${VERSION}" -o wallet .

# --- Final stage ---
FROM alpine:3.20

RUN addgroup -S app && adduser -S app -G app
WORKDIR /app
COPY --from=builder /app/wallet .
USER app

EXPOSE 8080
ENTRYPOINT ["./wallet"]
