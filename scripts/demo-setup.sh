#!/usr/bin/env bash
# One-time (idempotent) setup for the Axion Step 1 demo.
#
# Requires the devenv processes to be running: `devenv up -d` first.
#
# Creates the wallets, points the regtest miner at Bob's transparent
# address, funds and shields Bob's coinbase, and (once the advice commands
# exist in the devtool fork) pairs Alice's and Bob's SimpleX instances.
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

SERVER_ARGS=(-s 127.0.0.1:8137 --connection direct)
ACTIVATION="$DEMO_ROOT/configs/activation-heights.toml"
mkdir -p "$WALLETS_DIR"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "Checking out submodules (zcash-devtool @ axion-advice, zaino)"
git -C "$DEMO_ROOT" submodule update --init --recursive

step "Building zcash-devtool and zainod (no-op if up to date)"
(cd "$DEMO_ROOT/zcash-devtool" && cargo build --release --features regtest_support)
(cd "$DEMO_ROOT/zaino" && cargo build --release -p zainod)

step "Waiting for zebrad and zainod"
wait_for_zebra
wait_for_port 127.0.0.1 8137 "zainod gRPC"

init_wallet() {
    local name="$1" identity="$2"
    shift 2
    if [ -d "$WALLETS_DIR/$name" ]; then
        echo "wallet $name already exists, skipping init"
        return 0
    fi
    mkdir -p "$WALLETS_DIR/$name"
    wallet "$name" init \
        --name "$name" \
        --identity "$identity" \
        --birthday 1 \
        --network regtest \
        --activation-heights "$ACTIVATION" \
        "${SERVER_ARGS[@]}" \
        "$@"
}

step "Creating Bob's wallet (sender + regtest miner)"
init_wallet bob "$WALLETS_DIR/bob.age"

step "Pointing the regtest miner at Bob's Orchard address (shielded coinbase)"
# Zebra supports shielded coinbase: with an Orchard unified address as
# miner_address, block rewards land directly in Bob's shielded pool — no
# transparent shielding step, and the note commitment tree is non-empty
# from the first mined block.
BOB_ORCHARD=$(wallet bob list-addresses --receiver orchard \
    | grep -oE 'uregtest[0-9a-z]+' | head -1)
[ -n "$BOB_ORCHARD" ] || { echo "could not extract Bob's Orchard address" >&2; exit 1; }
echo "Bob's Orchard address: $BOB_ORCHARD"

if [ "$(cat "$RUN_DIR/miner-address" 2>/dev/null || true)" != "$BOB_ORCHARD" ]; then
    printf '%s' "$BOB_ORCHARD" > "$RUN_DIR/miner-address"
    # Bounce the container; process-compose restarts it with the new address.
    docker rm -f axion-zebrad >/dev/null 2>&1 || true
    sleep 2
    wait_for_zebra
fi

step "Mining shielded coinbase to Bob"
HEIGHT=$(chain_height)
mine 40
echo "chain height now $(chain_height) (was $HEIGHT)"

step "Syncing Bob"
wallet bob sync "${SERVER_ARGS[@]}"
wallet bob balance

step "Switching miner to a throwaway transparent address"
# Shielded coinbase needs an Orchard proof per block (~1.5s/block), which
# makes large `generate` calls crawl. Bob is funded now, so later blocks pay
# a burn-style transparent address and mine at full speed (~8 blocks/s).
THROWAWAY_TADDR="t27eWDgjFYJGVXmzrXeVjnb5J3uXDM9xH9v"
if [ "$(cat "$RUN_DIR/miner-address" 2>/dev/null || true)" != "$THROWAWAY_TADDR" ]; then
    printf '%s' "$THROWAWAY_TADDR" > "$RUN_DIR/miner-address"
    docker rm -f axion-zebrad >/dev/null 2>&1 || true
    sleep 2
    wait_for_zebra
fi

step "Creating Alice's wallets (same mnemonic, same birthday: honest race)"
init_wallet alice-oob "$WALLETS_DIR/alice.age"
if [ ! -d "$WALLETS_DIR/alice-scan" ]; then
    MNEMONIC=$(wallet alice-oob display-mnemonic --identity "$WALLETS_DIR/alice.age" --enable | tail -1)
    [ -n "$MNEMONIC" ] || { echo "could not read Alice's mnemonic" >&2; exit 1; }
    mkdir -p "$WALLETS_DIR/alice-scan"
    printf '%s\n' "$MNEMONIC" | wallet alice-scan restore-mnemonic \
        --name alice-scan \
        --identity "$WALLETS_DIR/alice.age" \
        --birthday 1 \
        --network regtest \
        --activation-heights "$ACTIVATION" \
        "${SERVER_ARGS[@]}"
else
    echo "wallet alice-scan already exists, skipping restore"
fi

step "Pairing SimpleX contacts (alice <-> bob)"
if "$DEVTOOL" advice --help >/dev/null 2>&1; then
    if [ -f "$RUN_DIR/simplex/paired" ]; then
        echo "already paired"
    else
        wait_for_port 127.0.0.1 5226 "simplex-alice WS"
        wait_for_port 127.0.0.1 5227 "simplex-bob WS"
        LINK_FILE="$RUN_DIR/simplex/invite-link"
        rm -f "$LINK_FILE"
        advice alice-oob pair --ws ws://127.0.0.1:5226 --mode invite \
            --link-out "$LINK_FILE" --identity "$WALLETS_DIR/alice.age" &
        INVITE_PID=$!
        wait_for_file "$LINK_FILE" "SimpleX invitation link" 60
        advice bob pair --ws ws://127.0.0.1:5227 --mode join --link "$(cat "$LINK_FILE")" \
            --identity "$WALLETS_DIR/bob.age"
        wait "$INVITE_PID"
        touch "$RUN_DIR/simplex/paired"
    fi
else
    echo "devtool has no 'advice' command yet — skipping SimpleX pairing"
fi

step "Setup complete"
echo "Chain height: $(chain_height)"
echo "Next: demo-noise (build chain history), then demo-race."
