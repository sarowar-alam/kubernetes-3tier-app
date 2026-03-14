# ---- Stage 1: Build ----
FROM node:18-alpine AS builder

WORKDIR /app

# Copy dependency files first (layer caching)
COPY package.json ./

# Install only production dependencies
RUN npm install --only=production

# Copy application source
COPY src/ ./src/

# ---- Stage 2: Runtime ----
FROM node:18-alpine

WORKDIR /app

# Create non-root user for security
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Copy built app from builder stage
COPY --from=builder /app /app

# Own the app directory
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "src/server.js"]
