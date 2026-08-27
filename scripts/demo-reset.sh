#!/usr/bin/env bash
# Factory reset: stop the background stack and wipe ALL demo state so the next
# `devenv up` starts from a clean chain, fresh wallets, and a fresh relay
# identity.
#
# Everything the demo produces lives under run/ (gitignored) and is wiped as a
# unit: run/zebra-state and run/wallets must go together (a wallet must never
# outlive the chain it synced), and run/smp — the relay's stable identity —
# goes with them.
set -euo pipefail
RUN_DIR="${RUN_DIR:?run inside 'devenv shell'}"
PARENT="$(dirname "$RUN_DIR")"
BASE="$(basename "$RUN_DIR")"

echo "Stopping the demo processes (if running)…"
devenv processes down 2>/dev/null || true

# zebrad and smp run in Docker with `restart = "always"` and bind-mount their
# state out of run/. Force-remove the containers and wait until they are gone,
# so they release those mounts before we wipe.
echo "Removing demo containers…"
docker rm -f axion-zebrad axion-smp >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qE '^axion-(zebrad|smp)$' || break
    sleep 1
done
if docker ps --format '{{.Names}}' | grep -qE '^axion-(zebrad|smp)$'; then
    echo "ERROR: a demo container is still running; refusing to wipe a live state dir." >&2
    exit 1
fi

# zebrad writes its bind-mounted state as the container's root user, so the host
# user cannot delete those files directly (rm -> Permission denied). Wipe run/
# from inside a throwaway root container that can, then clear any host-owned
# leftovers.
echo "Wiping ${RUN_DIR}…"
if [ -d "$RUN_DIR" ]; then
    docker run --rm -v "$PARENT:/host" busybox rm -rf "/host/$BASE" || true
fi
rm -rf "$RUN_DIR" 2>/dev/null || true
if [ -e "$RUN_DIR" ]; then
    echo "ERROR: could not fully remove ${RUN_DIR} (root-owned files left?)." >&2
    exit 1
fi

echo
echo "Clean slate. Bring the stack back up with:"
echo "    devenv up -d && demo-setup"
