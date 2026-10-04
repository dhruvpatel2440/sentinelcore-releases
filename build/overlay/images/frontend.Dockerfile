# Release frontend: compile main's Vite app to static files (no dev server, no
# source maps). build-release.sh extracts /dist into templates/frontend-dist,
# served by nginx. Main's frontend/Dockerfile (dev server) is never used.
ARG NODE_IMAGE=node:20-alpine
FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build && find dist -name '*.map' -delete

# Carrier stage: only holds /dist for `docker create` + `docker cp`.
FROM busybox:stable AS dist
COPY --from=build /app/dist /dist
