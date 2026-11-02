# Serves a Next.js app in standalone mode on port 3000.
# Build context must be the frontend directory (containing .next/ after npm run build).
# Node 24 LTS: Node 20 is end-of-life and its bundled Brotli decoder is
# vulnerable to CVE-2026-111497 with no fix (patched in 22.23.4 / 24.22.1).
FROM node:24-alpine
WORKDIR /app
COPY .next/standalone ./
COPY .next/static ./.next/static
COPY public ./public
EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"
CMD ["node", "server.js"]
