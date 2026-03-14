# ---- Stage 1: Build React app ----
FROM node:18-alpine AS builder

WORKDIR /app

# Copy dependency files first (layer caching)
COPY package.json ./

# Install all dependencies (including devDependencies for build)
RUN npm install

# Copy source files
COPY index.html ./
COPY vite.config.js ./
COPY src/ ./src/

# Build production bundle
RUN npm run build

# ---- Stage 2: Serve with Nginx ----
FROM nginx:1.25-alpine

# Remove default nginx config
RUN rm /etc/nginx/conf.d/default.conf

# Copy our custom nginx config
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy built React app from builder stage
COPY --from=builder /app/dist /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost/index.html || exit 1

CMD ["nginx", "-g", "daemon off;"]
