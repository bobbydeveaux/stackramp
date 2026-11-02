# StackRamp default Node.js Dockerfile
# Multi-stage build for production-ready Node apps.
# Detects package manager from lockfile (pnpm, yarn, or npm).

# Node 26 is the current LTS ("Lithium"). Stay on the newest LTS: older lines
# miss fixes such as CVE-2026-111497 (Brotli), which Node 20 never got.
FROM node:26-alpine AS builder

WORKDIR /app

# Node 25+ no longer ships corepack, so install it from npm first.
RUN npm install -g corepack && corepack enable

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

FROM node:26-alpine

WORKDIR /app

# Node 25+ no longer ships corepack, so install it from npm first.
RUN npm install -g corepack && corepack enable

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
