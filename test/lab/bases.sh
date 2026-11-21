#!/bin/sh
# bases.sh DOCKERFILE...: the images their FROMs name, tagged here before
# a build. bases.sh --list DOCKERFILE... prints them and pulls nothing.
#
# BuildKit asks Docker Hub for each base image's metadata at every build,
# unless the image is tagged on the machine. On a slow line that failed
# routescope's lab jobs with "net/http: TLS handshake timeout"
# (routescope docs/ci.md, "Base images"). Measured on routescope's CI VM:
# with the base tagged, "load metadata" takes 0.0 s and the build passes
# with Docker Hub blocked; with it in the build cache only, 1.6 to 5.3 s,
# and it fails when Hub is blocked.
#
# So a base is pulled once, through pull.sh, and kept. A tag kept is not
# refreshed: docker pull it to take a newer one.
set -u
list=
[ "${1:-}" = --list ] && { list=1; shift; }
here="$(dirname "$0")"

# Each FROM's image, with the ARG defaults put in, leaving out the
# file's own stages and scratch.
images() {
  for f in "$@"; do
    awk '
      toupper($1) == "ARG" {
        n = index($2, "="); if (n > 0) { k = substr($2, 1, n - 1); if (!(k in arg)) arg[k] = substr($2, n + 1) }
      }
      toupper($1) == "FROM" {
        i = 2; while (substr($i, 1, 2) == "--") i++
        img = $i
        for (k in arg) { gsub("\\$\\{" k "\\}", arg[k], img); gsub("\\$" k, arg[k], img) }
        if (!(tolower(img) in stage) && img != "scratch") print img
        if (toupper($(i + 1)) == "AS") stage[tolower($(i + 2))] = 1
      }' "$f" || exit 1
  done | awk '!seen[$0]++'
}

out="$(images "$@")" || exit 1
for img in $out; do
  if [ -n "$list" ]; then echo "$img"; continue; fi
  docker image inspect "$img" >/dev/null 2>&1 || "$here/pull.sh" "$img" >/dev/null || exit 1
done
