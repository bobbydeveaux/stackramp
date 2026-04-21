# Serves a pre-built SPA with a Go reverse proxy.
# Proxies /api/* to the backend with identity tokens for service-to-service auth.
# Build context must be the frontend directory (containing dist/ after npm run build).
# The proxy binary is built from the stackramp platform-action/proxy source.

FROM golang:1.23-alpine AS builder
WORKDIR /build
COPY .stackramp/platform-action/proxy/ .
RUN CGO_ENABLED=0 go build -o /proxy .

FROM alpine:3.20
WORKDIR /app
COPY --from=builder /proxy /usr/local/bin/proxy
COPY dist /app/dist
EXPOSE 8080
CMD ["proxy"]
