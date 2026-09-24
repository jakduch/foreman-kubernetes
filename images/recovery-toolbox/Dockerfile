FROM alpine:3.23.6@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0

LABEL org.opencontainers.image.title="Foreman Kubernetes recovery toolbox" \
      org.opencontainers.image.description="Minimal PostgreSQL, Restic, kubectl, and jq recovery environment" \
      org.opencontainers.image.source="https://github.com/theforeman/foreman-kubernetes"

RUN apk add --no-cache \
      ca-certificates \
      jq \
      kubectl \
      postgresql18-client \
      restic \
    && mkdir -p /work \
    && chmod 0700 /work

WORKDIR /work
