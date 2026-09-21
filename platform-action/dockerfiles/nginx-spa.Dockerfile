# Serves a pre-built Vite/React SPA from nginx on port 8080.
# Build context must be the frontend directory (containing dist/ after npm run build).
# When BACKEND_URL is set, /api/* requests are reverse-proxied to the backend service.
FROM nginx:alpine

ARG BACKEND_URL=""

# The stock entrypoint hook 10-listen-on-ipv6-by-default.sh runs `apk manifest nginx`
# at container start. Since apk-tools 3.0.8 (nginx:alpine from 2026-09-18) that
# read-only call downloads the package index over the network. On Cloud Run with
# --vpc-egress=all-traffic and no NAT it hangs, the container never binds :8080 and
# the startup probe fails. We write our own default.conf below, so the hook has
# nothing to do anyway — drop it.
RUN rm -f /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh

COPY dist /usr/share/nginx/html

# Generate nginx config — with optional /api reverse proxy
RUN { \
    echo 'server {'; \
    echo '  listen 8080;'; \
    echo '  root /usr/share/nginx/html;'; \
    echo '  index index.html;'; \
    echo '  location / { try_files $uri $uri/ /index.html; }'; \
    if [ -n "$BACKEND_URL" ]; then \
      echo "  location /api/ { proxy_pass ${BACKEND_URL}/api/; proxy_ssl_server_name on; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }"; \
    fi; \
    echo '}'; \
    } > /etc/nginx/conf.d/default.conf

EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
