ARG BASE_IMAGE=cgr.dev/chainguard/wolfi-base:latest

FROM ${BASE_IMAGE} AS builder

ARG JATTACH_VERSION=v2.2

USER root

RUN apk add --no-cache curl \
 && curl -fsSL -o /tmp/jattach \
      "https://github.com/jattach/jattach/releases/download/${JATTACH_VERSION}/jattach" \
 && chmod +x /tmp/jattach \
 && mkdir -p /usr/local/bin \
 && mv /tmp/jattach /usr/local/bin/jattach

FROM ${BASE_IMAGE}

USER root

RUN apk add --no-cache procps \
 && mkdir -p /usr/local/bin

COPY --from=builder /usr/local/bin/jattach /usr/local/bin/jattach
