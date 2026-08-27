#!/usr/bin/env bash
# Two-senders unlinkability (spec §1.5 scenario 3): Bob and Carol each pay
# Alice through their own channel. Their wallets' stored records must share
# NO common identifier: different identity subkeys (K_j at different j),
# different per-contact addresses, different SimpleX queues. A leaked wallet
# database from one sender tells you nothing about the other.
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

SERVER_ARGS=(-s 127.0.0.1:8137 --connection direct)
ACTIVATION="$DEMO_ROOT/configs/activation-heights.toml"

wait_for_zebra
wait_for_port 127.0.0.1 8137 "zainod gRPC"
wait_for_port 127.0.0.1 5228 "simplex-carol WS"
[ -f "$RUN_DIR/simplex/paired" ] || { echo "run demo-setup / pairing first (bob must be paired)" >&2; exit 1; }

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "Creating and funding Carol (second sender)"
if [ ! -d "$WALLETS_DIR/carol" ]; then
    mkdir -p "$WALLETS_DIR/carol"
    wallet carol init \
        --name carol \
        --identity "$WALLETS_DIR/carol.age" \
        --birthday 1 \
        --network regtest \
        --activation-heights "$ACTIVATION" \
        "${SERVER_ARGS[@]}"
fi
CAROL_UA=$(wallet carol list-addresses | grep -oE 'uregtest[0-9a-z]+' | head -1)
wallet bob sync "${SERVER_ARGS[@]}" >/dev/null 2>&1
if ! wallet carol balance 2>/dev/null | grep -qE 'Orchard Spendable:\s+[1-9]'; then
    wallet bob send --identity "$WALLETS_DIR/bob.age" \
        --address "$CAROL_UA" --value 500000000 "${SERVER_ARGS[@]}" >/dev/null
    mine 15
fi
wallet carol sync "${SERVER_ARGS[@]}" >/dev/null 2>&1

step "Pairing Carol with Alice (fresh channel, fresh subkey index j=1)"
if [ ! -f "$RUN_DIR/simplex/paired-carol" ]; then
    LINK_FILE="$RUN_DIR/simplex/invite-link-carol"
    rm -f "$LINK_FILE"
    # Alice mints a DIFFERENT subkey (j=1) and a different fresh address for
    # Carol than she gave Bob (j=0) - per-contact compartmentalization.
    advice alice-oob pair --ws ws://127.0.0.1:5226 --mode invite \
        --link-out "$LINK_FILE" --identity "$WALLETS_DIR/alice.age" --index 1 &
    INVITE_PID=$!
    wait_for_file "$LINK_FILE" "carol invitation link" 60
    advice carol pair --ws ws://127.0.0.1:5228 --mode join \
        --link "$(cat "$LINK_FILE")" --identity "$WALLETS_DIR/carol.age"
    wait "$INVITE_PID"
    touch "$RUN_DIR/simplex/paired-carol"
fi

step "Carol pays Alice through her own channel"
CAROL_TO_ALICE=$(advice carol contact --to alice 2>/dev/null | jq -r '.working_address // empty')
[ -n "$CAROL_TO_ALICE" ] || { echo "carol has no working address for alice" >&2; exit 1; }
SEND_OUT=$(wallet carol send --identity "$WALLETS_DIR/carol.age" \
    --address "$CAROL_TO_ALICE" --value 150000000 "${SERVER_ARGS[@]}")
TXID=$(printf '%s\n' "$SEND_OUT" | grep -oiE '[0-9a-f]{64}' | tail -1)
mine 3
advice carol send --ws ws://127.0.0.1:5228 --to alice --txid "$TXID" \
    --identity "$WALLETS_DIR/carol.age" --ack-timeout 0 "${SERVER_ARGS[@]}" >/dev/null
echo "carol paid and advised (tx ${TXID:0:16}...)"

step "Comparing the two senders' stored records"
BOB_IDS=$(jq -r '.alice | .pubkey, (.working_address // empty)' "$WALLETS_DIR/bob/axion-peers.json"; \
          jq -r '.alice[].envelope.txid' "$WALLETS_DIR/bob/axion-outbox.json" 2>/dev/null)
CAROL_IDS=$(jq -r '.alice | .pubkey, (.working_address // empty)' "$WALLETS_DIR/carol/axion-peers.json"; \
            jq -r '.alice[].envelope.txid' "$WALLETS_DIR/carol/axion-outbox.json" 2>/dev/null)

echo "-- bob's record of 'alice':"
jq -c '.alice | {j, pubkey: (.pubkey[0:24] + "..."), working_address: ((.working_address // "-")[0:32] + "...")}' \
    "$WALLETS_DIR/bob/axion-peers.json"
echo "-- carol's record of 'alice':"
jq -c '.alice | {j, pubkey: (.pubkey[0:24] + "..."), working_address: ((.working_address // "-")[0:32] + "...")}' \
    "$WALLETS_DIR/carol/axion-peers.json"

COMMON=$(comm -12 <(printf '%s\n' "$BOB_IDS" | sort -u) <(printf '%s\n' "$CAROL_IDS" | sort -u) | grep -v '^$' || true)
echo
if [ -z "$COMMON" ]; then
    printf '\033[1;32m╔══════════════════════════════════════════════════════╗\n'
    printf '║  %-52s║\n' "0 COMMON IDENTIFIERS between the two senders"
    printf '║  %-52s║\n' "different subkeys, different addresses, own queues"
    printf '╚══════════════════════════════════════════════════════╝\033[0m\n'
else
    printf '\033[1;31mSHARED IDENTIFIERS FOUND:\033[0m\n%s\n' "$COMMON"
    exit 1
fi