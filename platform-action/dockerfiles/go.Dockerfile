# Launchpad default Go Dockerfile
# Multi-stage build for production-ready Go apps

FROM golang:1.22-alpine AS builder

WORKDIR /app

COPY go.mod go.sum* ./
RUN go mod download

COPY . .

# Build: try cmd/server first, fall back to root package
RUN if [ -d "cmd/server" ]; then \
      CGO_ENABLED=0 go build -o /app/server ./cmd/server; \
    else \
      CGO_ENABLED=0 go build -o /app/server .; \
    fi

FROM alpine:3.19

RUN apk --no-cache add ca-certificates

WORKDIR /app
COPY --from=builder /app/server .

ENV PORT=8080
EXPOSE ${PORT}

CMD ["/app/server"]
