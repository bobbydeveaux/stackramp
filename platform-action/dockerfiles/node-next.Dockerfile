# Serves a Next.js app in standalone mode on port 3000.
# Build context must be the frontend directory (containing .next/ after npm run build).
# Node 26 is the current LTS ("Lithium"). Stay on the newest LTS: older lines
# miss fixes such as CVE-2026-111497 (Brotli), which Node 20 never got.
FROM node:26-alpine
WORKDIR /app
COPY .next/standalone ./
COPY .next/static ./.next/static
COPY public ./public
EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"
CMD ["node", "server.js"]
