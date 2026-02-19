# =============================================================================
# Stage 1: Build
# =============================================================================
FROM node:20-alpine AS builder

WORKDIR /app

# Install dependencies first (layer caching)
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

# Copy source and build
COPY . .

# Build args for Vite env vars (baked at compile time)
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_ANON_KEY
ARG VITE_GOOGLE_API_KEY
ARG VITE_SENTRY_DSN
ARG VITE_APP_VERSION
ARG VITE_N8N_WEBHOOK_URL
ARG VITE_N8N_FACTURA_WEBHOOK_URL

RUN npm run build

# =============================================================================
# Stage 2: Serve
# =============================================================================
FROM nginx:1.27-alpine

# Remove default config
RUN rm /etc/nginx/conf.d/default.conf

# Copy nginx config as template (envsubst replaces ${N8N_UPSTREAM} at startup)
COPY nginx.conf /etc/nginx/conf.d/default.conf.template

# Copy built assets
COPY --from=builder /app/dist /usr/share/nginx/html

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost/ || exit 1

# N8N upstream URL for reverse proxy (set at runtime, e.g. https://n8n.shycia.com.ar)
ENV N8N_UPSTREAM=""

EXPOSE 80

# At startup: substitute N8N_UPSTREAM in nginx template, then start nginx
CMD ["/bin/sh", "-c", "envsubst '${N8N_UPSTREAM}' < /etc/nginx/conf.d/default.conf.template > /etc/nginx/conf.d/default.conf && nginx -g 'daemon off;'"]
