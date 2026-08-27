#!/usr/bin/env bash
# Video window: ALICE creates the contact invitation — the spec's contact
# token (§1.3.5). The invitation link is rendered as a QR code in the
# terminal while she waits for Bob to scan/join it.
# QR=0 skips the QR rendering.
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

LINK_FILE="$RUN_DIR/simplex/invite-link"

wait_for_port 127.0.0.1 5226 "simplex-alice WS"
mkdir -p "$RUN_DIR/simplex"
rm -f "$LINK_FILE"

printf '\n\033[1m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "ALICE - creating a contact invitation"
printf '║  %-52s║\n' "(the contact token: scan it from Bob's window)"
printf '╚══════════════════════════════════════════════════════╝\033[0m\n\n'

# Render the QR as soon as the pair command writes the link, while it keeps
# waiting in the foreground for Bob to connect.
(
    wait_for_file "$LINK_FILE" "invitation link" 60 >/dev/null 2>&1 || exit 0
    echo
    if [ "${QR:-1}" = "1" ] && command -v qrencode >/dev/null; then
        qrencode -t ANSIUTF8 -m 1 < "$LINK_FILE" || true
        echo
    fi
    echo "invitation link (same content as the QR):"
    cat "$LINK_FILE"
    echo
    echo "waiting for Bob to join ..."
) &

# --identity mints the seed-derived identity token (K_j) and hands it to
# Bob over the fresh channel — his anchor for verifying a future recovery.
advice alice-oob pair \
    --ws ws://127.0.0.1:5226 \
    --mode invite \
    --link-out "$LINK_FILE" \
    --identity "$WALLETS_DIR/alice.age" >/dev/null

touch "$RUN_DIR/simplex/paired"
printf '\n\033[1;32m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "CHANNEL ESTABLISHED - contact: bob"
printf '║  %-52s║\n' "E2E encrypted, via the self-hosted local relay"
printf '╚══════════════════════════════════════════════════════╝\033[0m\n'
