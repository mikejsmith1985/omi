#!/usr/bin/env bash
# Bridge the harness's loopback-bound services onto 0.0.0.0 so Docker's published
# ports reach them.
#
# The harness hardcodes 127.0.0.1 for every service (dev_harness/config.py), which is
# correct for its intended use — a developer's own machine — but means a published
# container port forwards to a closed socket. socat listens on all interfaces at
# port+10000 and forwards to the real loopback port, so the mapping is:
#
#   container 18000 -> 127.0.0.1:8000   backend API
#   container 19099 -> 127.0.0.1:9099   Firebase Auth emulator
#
# Only these two are bridged because they are the only ones a phone talks to.
# Firestore, Redis and Typesense stay loopback-only, which is where they belong.

set -euo pipefail

declare -a BRIDGES=(
  "18000:8000"
  "19099:9099"
)

for bridge in "${BRIDGES[@]}"; do
  outside="${bridge%%:*}"
  inside="${bridge##*:}"
  socat "TCP-LISTEN:${outside},fork,reuseaddr" "TCP:127.0.0.1:${inside}" &
  echo "bridging 0.0.0.0:${outside} -> 127.0.0.1:${inside}"
done

wait
