FROM alpine:latest

RUN apk add --no-cache file curl jq sed grep

COPY entrypoint.sh /

RUN chmod +x /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh" ]
