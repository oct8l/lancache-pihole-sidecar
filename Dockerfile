FROM alpine:3.20

RUN apk add --no-cache bash git jq ca-certificates coreutils docker-cli

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
