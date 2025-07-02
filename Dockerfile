
FROM golang:1.24-alpine AS builder

WORKDIR /throttler
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN go build -o /out/throttler

FROM kong/kong-gateway:3.10.0.0
USER root

COPY --from=builder /out/throttler /usr/local/bin/throttler
COPY ./kong/plugins/gubernator /usr/local/share/lua/5.1/kong/plugins/gubernator
ENV KONG_PLUGINS=bundled,throttler,gubernator   

COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY kong.conf /etc/kong/kong.conf
COPY gubernator.conf /etc/kong/gubernator.conf

USER kong
  
ENTRYPOINT ["/docker-entrypoint.sh"]
  
EXPOSE 8000 8443 8001 8444 8002 8445 8003 8446 8004 8447
  
STOPSIGNAL SIGQUIT
  
HEALTHCHECK --interval=10s --timeout=10s --retries=10 CMD kong health

CMD ["kong", "docker-start"]