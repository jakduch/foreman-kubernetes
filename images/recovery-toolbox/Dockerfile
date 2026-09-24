FROM alpine:3.23

RUN apk add --no-cache \
      ca-certificates \
      jq \
      kubectl \
      postgresql18-client \
      restic \
    && mkdir -p /work \
    && chmod 0700 /work

WORKDIR /work

