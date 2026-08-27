#!/usr/bin/env bash
# Bob pays Alice 2.5 ZEC (standard shielded transaction), mines it, and
# pushes out-of-band advice over SimpleX.
#
# Prints the txid and the advice envelope. Used standalone or from demo-race.
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

SERVER_ARGS=(-s 127.0.0.1:8137 --connection direct)
AMOUNT_ZAT="${AMOUNT_ZAT:-250000000}"   # 2.5 ZEC

wait_for_zebra
wait_for_port 127.0.0.1 8137 "zainod gRPC"

# Pay the ratcheted per-contact address from Bob's peer store (each accepted
# ack rotates it); fall back to Alice's default address before first pairing
# with the address-carrying token.
ALICE_UA=$(advice bob contact --to alice 2>/dev/null | jq -r '.working_address // empty' || true)
if [ -z "$ALICE_UA" ]; then
    ALICE_UA=$(wallet alice-oob list-addresses | grep -oE 'uregtest[0-9a-z]+' | head -1)
fi
[ -n "$ALICE_UA" ] || { echo "could not determine Alice's address" >&2; exit 1; }
echo "paying to: ${ALICE_UA:0:40}... (ratcheted per-contact address)"

echo "== Bob pays Alice ${AMOUNT_ZAT} zatoshis"
wallet bob sync "${SERVER_ARGS[@]}" >/dev/null
SEND_OUT=$(wallet bob send \
    --identity "$WALLETS_DIR/bob.age" \
    --address "$ALICE_UA" \
    --value "$AMOUNT_ZAT" \
    "${SERVER_ARGS[@]}")
echo "$SEND_OUT"

TXID=$(printf '%s\n' "$SEND_OUT" | grep -oiE '[0-9a-f]{64}' | tail -1)
[ -n "$TXID" ] || { echo "could not extract txid from send output" >&2; exit 1; }
echo "txid: $TXID"

echo "== Mining the payment"
mine 3

if [ "${NO_ADVICE:-0}" = "1" ]; then
    echo "== NO_ADVICE=1: skipping out-of-band advice (fallback-rail scenario)"
else
    echo "== Sending out-of-band advice over SimpleX (signed; waits for ack)"
    advice bob send \
        --ws ws://127.0.0.1:5227 \
        --to alice \
        --txid "$TXID" \
        --identity "$WALLETS_DIR/bob.age" \
        "${SERVER_ARGS[@]}"
fi

printf '%s' "$TXID" > "$RUN_DIR/last-payment-txid"
