# Serves a pre-built Vite/React SPA from nginx on port 8080.
# Build context must be the frontend directory (containing dist/ after npm run build).
FROM nginx:alpine
COPY dist /usr/share/nginx/html
RUN echo 'server { listen 8080; root /usr/share/nginx/html; index index.html; location / { try_files $uri $uri/ /index.html; } }' \
    > /etc/nginx/conf.d/default.conf
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
