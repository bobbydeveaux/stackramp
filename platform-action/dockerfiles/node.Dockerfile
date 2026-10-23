# StackRamp default Node.js Dockerfile
# Multi-stage build for production-ready Node apps.
# Detects package manager from lockfile (pnpm, yarn, or npm).

# Node 24 LTS: Node 20 is end-of-life and its bundled Brotli decoder is
# vulnerable to CVE-2026-111497 with no fix (patched in 22.23.4 / 24.22.1).
FROM node:24-alpine AS builder

WORKDIR /app

RUN corepack enable

COPY package.json ./
COPY package-lock.json* pnpm-lock.yaml* yarn.lock* ./

RUN if [ -f pnpm-lock.yaml ]; then \
      pnpm install --frozen-lockfile; \
    elif [ -f yarn.lock ]; then \
      yarn install --frozen-lockfile; \
    else \
      npm ci; \
    fi

COPY . .

FROM node:24-alpine

WORKDIR /app

RUN corepack enable

COPY package.json ./
COPY package-lock.json* pnpm-lock.yaml* yarn.lock* ./

RUN if [ -f pnpm-lock.yaml ]; then \
      pnpm install --prod --frozen-lockfile; \
    elif [ -f yarn.lock ]; then \
      yarn install --production --frozen-lockfile; \
    else \
      npm ci --omit=dev; \
    fi

COPY --from=builder /app .

ENV PORT=8080
EXPOSE ${PORT}

# Try src/index.js first, fall back to index.js
CMD ["sh", "-c", "if [ -f src/index.js ]; then node src/index.js; else node index.js; fi"]
