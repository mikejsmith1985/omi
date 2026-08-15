#!/usr/bin/env bash
# Start, stop and inspect the containerised Omi dev harness.
#
# The harness itself is Linux-only in practice: it hard-requires `redis-server` and a
# Java runtime on PATH, and Windows has no official Redis build. Running it in a
# container gives those without touching the host, and publishes the two ports a
# phone on the same Wi-Fi needs.
#
#   ./scripts/harness.sh up       build if needed, then start
#   ./scripts/harness.sh down     stop and remove the container
#   ./scripts/harness.sh status   service health as the harness reports it
#   ./scripts/harness.sh logs     follow the container log
#   ./scripts/harness.sh shell    interactive shell inside the container
#   ./scripts/harness.sh ip       the URLs to point a build at

set -euo pipefail

CONTAINER=omi-harness-run
IMAGE=omi-harness
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Docker on Windows needs a native path for the bind mount; Git Bash's /c/... form
# is not understood by the daemon.
mount_source() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) printf '%s' "$(cygpath -w "$REPO_ROOT" | tr '\\' '/')" ;;
    *) printf '%s' "$REPO_ROOT" ;;
  esac
}

lan_ip() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      powershell.exe -NoProfile -Command \
        "(Get-NetIPConfiguration | Where-Object { \$_.IPv4DefaultGateway -ne \$null -and \$_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1 -ExpandProperty IPv4Address).IPAddress" \
        2>/dev/null | tr -d '\r\n'
      ;;
    *) hostname -I 2>/dev/null | awk '{print $1}' ;;
  esac
}

case "${1:-up}" in
  up)
    docker image inspect "$IMAGE" >/dev/null 2>&1 || \
      docker build -f "$REPO_ROOT/Dockerfile.harness" -t "$IMAGE" "$REPO_ROOT"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    # Published ports are the host-facing numbers; the container-side numbers are the
    # socat bridges, because every harness service binds loopback only.
    docker run -d --name "$CONTAINER" \
      -v "$(mount_source):/repo" \
      -e PROVIDER_MODE=offline \
      -p 8000:18000 \
      -p 9099:19099 \
      "$IMAGE" \
      bash -lc 'harness-expose & cd /repo && bash scripts/dev-harness/dev-up.sh; tail -f /dev/null'
    echo "started; follow with: $0 logs"
    ;;
  down)
    docker rm -f "$CONTAINER" >/dev/null 2>&1 && echo "stopped" || echo "not running"
    ;;
  status)
    docker exec "$CONTAINER" bash -lc 'cd /repo && bash scripts/dev-harness/dev-status.sh'
    ;;
  logs)
    docker logs -f "$CONTAINER"
    ;;
  shell)
    docker exec -it "$CONTAINER" bash
    ;;
  ip)
    ip="$(lan_ip)"
    if [ -z "$ip" ]; then
      echo "could not determine the LAN address; run ipconfig and read the Wi-Fi IPv4" >&2
      exit 1
    fi
    echo "OMI_API_BASE_URL=http://${ip}:8000/"
    echo "OMI_FIREBASE_AUTH_EMULATOR_HOST=${ip}"
    ;;
  *)
    echo "usage: $0 {up|down|status|logs|shell|ip}" >&2
    exit 1
    ;;
esac
