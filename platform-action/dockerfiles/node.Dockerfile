# StackRamp default Node.js Dockerfile
# Multi-stage build for production-ready Node apps.
# Detects package manager from lockfile (pnpm, yarn, or npm).

FROM node:20-alpine AS builder

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

FROM node:20-alpine

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
