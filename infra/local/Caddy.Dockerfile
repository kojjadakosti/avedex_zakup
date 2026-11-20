# Caddy's upstream binary carries cap_net_bind_service in file capabilities.
# With cap_drop: ALL + no-new-privileges, Linux refuses to exec that binary.
# Port 8080 is unprivileged: remove file capabilities and run without root.
FROM caddy:2.10-alpine
RUN apk add --no-cache libcap \
    && setcap -r /usr/bin/caddy \
    && apk del libcap
USER 1000:1000
