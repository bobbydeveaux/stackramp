# Serves a pre-built Vite/React SPA from nginx on port 8080.
# Build context must be the frontend directory (containing dist/ after npm run build).
# When BACKEND_URL is set, /api/* requests are reverse-proxied to the backend service.
FROM nginx:alpine

ARG BACKEND_URL=""

COPY dist /usr/share/nginx/html

# Generate nginx config — with optional /api reverse proxy
RUN { \
    echo 'server {'; \
    echo '  listen 8080;'; \
    echo '  root /usr/share/nginx/html;'; \
    echo '  index index.html;'; \
    echo '  location / { try_files $uri $uri/ /index.html; }'; \
    if [ -n "$BACKEND_URL" ]; then \
      echo "  location /api/ { proxy_pass ${BACKEND_URL}/api/; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }"; \
    fi; \
    echo '}'; \
    } > /etc/nginx/conf.d/default.conf

EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
