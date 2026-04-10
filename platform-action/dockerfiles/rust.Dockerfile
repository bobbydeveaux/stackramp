# StackRamp default Rust Dockerfile
# Multi-stage build for production-ready Rust apps

FROM rust:1.87-slim AS builder

WORKDIR /app

# Cache dependency builds
COPY Cargo.toml Cargo.lock* ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src

COPY . .
RUN touch src/main.rs && cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/target/release/* /app/ 2>/dev/null || true

# Find the binary (first executable in /app that isn't a .d file)
RUN BINARY=$(find /app -maxdepth 1 -type f -executable ! -name '*.d' | head -1) && \
    ln -sf "$BINARY" /app/server

ENV PORT=8080
EXPOSE ${PORT}

CMD ["/app/server"]
