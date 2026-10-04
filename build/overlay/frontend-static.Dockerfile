# Overlay multi-stage build for the RELEASE frontend: compile the Vite app to
# static files, no dev server, no source maps. The build script extracts the
# resulting /dist and ships it as static assets served by nginx. This never
# edits the source frontend/Dockerfile (which stays dev-only).
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
# Production build; Vite drops the dev server and (by default) source maps.
RUN npm run build

# Carrier stage: a tiny image whose only job is to hold /dist so the build
# script can `docker create` + `docker cp` it out deterministically.
FROM busybox:stable AS dist
COPY --from=build /app/dist /dist
