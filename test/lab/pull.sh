#!/bin/sh
# pull.sh IMAGE: docker pull, tried three times, 15 seconds apart.
#
# A registry's CDN sometimes drops the connection in the middle of a layer:
# CI run 249's bgp job failed in 2 seconds with "failed to copy:
# httpReadSeeker: failed open: ... cdn01.quay.io ...: EOF" while the clab
# job of the same run pulled the same image. One dropped connection should
# not fail a job.
set -u
image="$1"
for try in 1 2 3; do
  docker pull -q "$image" && exit 0
  [ "$try" = 3 ] && break
  echo "pull.sh: $image failed (try $try of 3), again in 15 s" >&2
  sleep 15
done
echo "pull.sh: $image failed 3 times" >&2
exit 1
