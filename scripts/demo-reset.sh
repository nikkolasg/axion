#!/usr/bin/env bash
# Factory reset: stop the background stack and wipe ALL demo state so the next
# `devenv up` starts from a clean chain, fresh wallets, and a fresh relay
# identity.
#
# Everything the demo produces lives under run/ (gitignored). It is wiped as a
# unit on purpose: run/zebra-state and run/wallets must go together (a wallet
# must never outlive the chain it synced), and run/smp — the relay's stable
# identity — goes with them.
set -euo pipefail
RUN_DIR="${RUN_DIR:?run inside 'devenv shell'}"

echo "Stopping the demo processes (if running)…"
devenv processes down 2>/dev/null || true

echo "Wiping ${RUN_DIR}…"
rm -rf "$RUN_DIR"

echo
echo "Clean slate. Bring the stack back up with:"
echo "    devenv up -d && demo-setup"
