# Serves a static frontend (no build step) from nginx on port 8080.
# Build context must be the frontend directory (containing index.html and static assets).
# Pass --build-arg SPA=true to enable SPA catch-all routing (all paths → index.html).
FROM nginx:alpine
ARG SPA=false
COPY . /usr/share/nginx/html
RUN if [ "$SPA" = "true" ]; then \
      echo 'server { listen 8080; root /usr/share/nginx/html; index index.html; location / { try_files $uri $uri/ /index.html; } }' \
        > /etc/nginx/conf.d/default.conf; \
    else \
      echo 'server { listen 8080; root /usr/share/nginx/html; index index.html; }' \
        > /etc/nginx/conf.d/default.conf; \
    fi
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
