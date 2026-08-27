#!/usr/bin/env bash
# Video window: BOB consumes Alice's contact invitation (in real life he
# scans her QR; here the link is read from the shared file the moment her
# window displays it).
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

LINK_FILE="$RUN_DIR/simplex/invite-link"

wait_for_port 127.0.0.1 5227 "simplex-bob WS"

printf '\n\033[1m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "BOB - waiting for Alice's invitation ..."
printf '║  %-52s║\n' "(run demo-pair-alice in her window)"
printf '╚══════════════════════════════════════════════════════╝\033[0m\n\n'

wait_for_file "$LINK_FILE" "Alice's invitation link" 300
echo "invitation received - connecting ..."

# --identity: bob sends his own identity token back, so alice can verify
# the signatures on his future advice envelopes.
advice bob pair \
    --ws ws://127.0.0.1:5227 \
    --mode join \
    --link "$(cat "$LINK_FILE")" \
    --identity "$WALLETS_DIR/bob.age"

printf '\n\033[1;32m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "CHANNEL ESTABLISHED - contact: alice"
printf '║  %-52s║\n' "Bob can now pay & advise without scanning anything"
printf '╚══════════════════════════════════════════════════════╝\033[0m\n'
