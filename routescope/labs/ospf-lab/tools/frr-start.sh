#!/bin/sh
# Starts FRR in the router lab, with /etc/frr mounted from the lab folder.
#
# vtysh's "write memory" runs as root and gives frr.conf to FRR's own
# user, mode 0600, so the lab folder's owner can no longer read it, nor
# can git. Every 2 seconds this gives it back to the owner of the folder,
# mode 0640. FRR itself runs as root at start, so it still reads it.

conf=/etc/frr/frr.conf
owner=$(stat -c %u:%g /etc/frr)

(
  while sleep 2; do
    [ -f "$conf" ] || continue
    [ "$(stat -c %u:%g "$conf")" = "$owner" ] && [ "$(stat -c %a "$conf")" = 640 ] && continue
    chown "$owner" "$conf" && chmod 0640 "$conf"
  done
) &

exec /usr/lib/frr/docker-start
