#!/usr/bin/env bash
# Wipe the SimpleX state (both chat databases and the pairing marker) so a
# video take can show the contact establishment from scratch. The wallets
# and the chain are untouched.
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

pkill -f 'zcash-devtool advice' 2>/dev/null || true
rm -f "$RUN_DIR/simplex/paired" "$RUN_DIR/simplex/invite-link"
rm -rf "$RUN_DIR/simplex/alice" "$RUN_DIR/simplex/bob"

# Kill the CLIs directly; process-compose (availability.restart = always)
# brings them back with fresh databases and profiles.
pkill -f "simplex-chat -d $RUN_DIR/simplex/" 2>/dev/null || true
sleep 3
wait_for_port 127.0.0.1 5226 "simplex-alice WS"
wait_for_port 127.0.0.1 5227 "simplex-bob WS"
# The CLI needs a moment after binding to finish creating the bot profile.
sleep 3
echo "SimpleX state reset - fresh profiles, no contacts."
echo "Pair again with demo-pair-alice / demo-pair-bob."
