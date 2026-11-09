# restic binary from the official image, on a current Alpine base.
# Renovate tracks both FROM lines.
FROM restic/restic:0.19.1 AS restic

FROM alpine:3.24.4

RUN apk upgrade --no-cache \
 && apk add --no-cache ca-certificates curl sqlite tar tzdata

COPY --from=restic /usr/bin/restic /usr/bin/restic
COPY backup.sh /usr/local/bin/backup.sh

# Runs as an unprivileged user by default; each CronJob sets runAsUser to the
# UID that owns its app's files (vaultwarden: 1000).
USER 10001

ENTRYPOINT ["/usr/local/bin/backup.sh"]
