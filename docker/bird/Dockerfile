# BIRD 2 for the router lab: a fourth OSPF implementation on the segment.
# Debian's bird2 package; the configuration comes from the lab folder.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends bird2 iproute2 \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/bird
# Foreground, logging to stderr (docker logs), control socket where birdc looks.
ENTRYPOINT ["bird", "-f", "-c", "/etc/bird/bird.conf", "-s", "/run/bird/bird.ctl"]
