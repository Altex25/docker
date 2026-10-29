ARG NODE_IMAGE=node:20.20.2-alpine3.23@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293
ARG DISTROLESS_IMAGE=gcr.io/distroless/nodejs20-debian12:nonroot@sha256:2cd820156cf039c8b54ae2d2a97e424b6729070714de8707a6b79f20d56f6a9a

FROM ${NODE_IMAGE} AS base
WORKDIR /app
COPY package.json package-lock.json ./

FROM base AS deps-dev
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund \
    && npm ls --depth=0 >/dev/null

FROM base AS deps-prod
ENV NODE_ENV=production
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --no-audit --no-fund \
    && npm ls --omit=dev --depth=0 >/dev/null

FROM deps-dev AS test
COPY src ./src
COPY test ./test
RUN npm run lint && npm test

FROM ${DISTROLESS_IMAGE} AS runtime-distroless

ARG DISTROLESS_IMAGE
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://github.com/Altex25/docker

LABEL org.opencontainers.image.title="shopapi" \
      org.opencontainers.image.description="API catalogue produits Shop SAS (distroless)" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="${DISTROLESS_IMAGE}"

ENV NODE_ENV=production \
    APP_VERSION=${APP_VERSION} \
    PORT=3000

USER 0:0
WORKDIR /app

COPY --from=deps-prod /app/node_modules ./node_modules
COPY package.json ./
COPY --from=test /app/src ./src

USER 65532:65532
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --start-interval=1s --retries=3 \
    CMD ["/nodejs/bin/node", "-e", "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

CMD ["src/server.js"]

FROM ${NODE_IMAGE} AS runtime

ARG NODE_IMAGE
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://github.com/Altex25/docker

LABEL org.opencontainers.image.title="shopapi" \
      org.opencontainers.image.description="API catalogue produits Shop SAS" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="${NODE_IMAGE}"

ENV NODE_ENV=production \
    APP_VERSION=${APP_VERSION} \
    PORT=3000

WORKDIR /app

COPY --from=deps-prod /app/node_modules ./node_modules
COPY package.json ./
COPY --from=test /app/src ./src

USER 1000:1000
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --start-interval=1s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:3000/health"]

CMD ["node", "src/server.js"]
