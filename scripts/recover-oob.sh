#!/usr/bin/env bash
# Video window: ALICE after losing her device. She restores from the seed
# phrase ALONE (all channel state gone), opens a brand-new SimpleX channel,
# proves she is the same identity with a seed-derived signature, and gets
# every past advice re-delivered — each one verified against the chain with
# a targeted decryption. No chain scan.
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

SERVER_ARGS=(-s 127.0.0.1:8137 --connection direct)
LINK_FILE="$RUN_DIR/simplex/recovery-link"
LOG="$RUN_DIR/recover-oob.log"
ACTIVATION="$DEMO_ROOT/configs/activation-heights.toml"

printf '\n\033[1m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "ALICE - device lost."
printf '║  %-52s║\n' "restoring from the seed phrase ONLY"
printf '╚══════════════════════════════════════════════════════╝\033[0m\n\n'

# The seed phrase is the one thing she still has (in real life: typed in).
MNEMONIC=$(wallet alice-oob display-mnemonic --identity "$WALLETS_DIR/alice.age" --enable | tail -1)
[ -n "$MNEMONIC" ] || { echo "could not read the demo seed phrase" >&2; exit 1; }

# Fresh wallet from seed; fresh messaging state (new device: the old
# simplex database is gone with the old device).
rm -rf "$WALLETS_DIR/alice-recovered"
mkdir -p "$WALLETS_DIR/alice-recovered"
echo "restoring wallet from seed ..."
printf '%s\n' "$MNEMONIC" | wallet alice-recovered restore-mnemonic \
    --name alice-recovered \
    --identity "$WALLETS_DIR/alice.age" \
    --birthday 1 \
    --network regtest \
    --activation-heights "$ACTIVATION" \
    "${SERVER_ARGS[@]}" >/dev/null
pkill -f "simplex-chat -d $RUN_DIR/simplex/alice/" 2>/dev/null || true
rm -rf "$RUN_DIR/simplex/alice"
sleep 3
wait_for_port 127.0.0.1 5226 "simplex-alice WS (new device)"
sleep 3

echo "wallet restored (empty: no payment knowledge yet). Balance:"
wallet alice-recovered balance 2>/dev/null | grep -E 'Balance:' | grep -v '{' || true
echo
echo "opening a NEW channel and proving identity to bob (seed-derived key) ..."
rm -f "$LINK_FILE"

advice alice-recovered recover \
    --ws ws://127.0.0.1:5226 \
    --identity "$WALLETS_DIR/alice.age" \
    --link-out "$LINK_FILE" \
    "${SERVER_ARGS[@]}" 2>&1 | tee "$LOG"

SUMMARY=$(grep -oE 'RECOVERY COMPLETE: .*' "$LOG" | head -1 || true)
N=$(printf '%s' "$SUMMARY" | grep -oE 'restored [0-9]+ payments' | grep -oE '[0-9]+' || echo "?")
VAL=$(printf '%s' "$SUMMARY" | grep -oE 'totalling [0-9.]+ ZEC' | grep -oE '[0-9.]+' || echo "?")
TRANS=$(printf '%s' "$SUMMARY" | grep -oE 'transfer [0-9]+ms' | grep -oE '[0-9]+' || echo "?")
VER=$(printf '%s' "$SUMMARY" | grep -oE 'verification [0-9]+ms' | grep -oE '[0-9]+' || echo "?")
printf '\n\033[1;32m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "RECOVERED $N payments ($VAL ZEC)"
printf '║  %-52s║\n' "chain work: ${VER}ms (targeted decryptions)"
printf '║  %-52s║\n' "messaging: ${TRANS}ms (constant in chain size)"
printf '╚══════════════════════════════════════════════════════╝\033[0m\n'
echo
echo "recovered wallet's view of its payments:"
wallet alice-recovered list-tx 2>/dev/null | grep -E 'Value|Received by' | tail -6 || true
