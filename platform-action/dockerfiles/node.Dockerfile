# Launchpad default Node.js Dockerfile
# Multi-stage build for production-ready Node apps

FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .

FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY --from=builder /app .

ENV PORT=8080
EXPOSE ${PORT}

# Try src/index.js first, fall back to index.js
CMD ["sh", "-c", "if [ -f src/index.js ]; then node src/index.js; else node index.js; fi"]
