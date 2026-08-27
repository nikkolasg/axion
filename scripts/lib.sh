# Shared helpers for the Axion Step 1 demo scripts. Sourced, not executed.

: "${DEMO_ROOT:?DEMO_ROOT not set (run inside devenv shell)}"
: "${RUN_DIR:?RUN_DIR not set (run inside devenv shell)}"

ZEBRA_RPC_URL="${ZEBRA_RPC_URL:-http://127.0.0.1:18232}"
SMP_ADDRESS_FILE="$RUN_DIR/smp/address"

DEVTOOL="$DEMO_ROOT/zcash-devtool/target/release/zcash-devtool"
WALLETS_DIR="$RUN_DIR/wallets"

# zebra_rpc <method> [params-json]  -> prints .result, fails on RPC error
zebra_rpc() {
    local method="$1" params="${2:-[]}" resp
    resp=$(curl -sf -H 'content-type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "$ZEBRA_RPC_URL")
    if [ "$(printf '%s' "$resp" | jq -r 'has("error") and .error != null')" = "true" ]; then
        echo "zebra RPC $method failed: $(printf '%s' "$resp" | jq -c .error)" >&2
        return 1
    fi
    printf '%s' "$resp" | jq -r '.result'
}

# mine <n> — mine n blocks instantly on regtest. After long mining runs
# zebra's block-gossip channel fills and every `generate` fails with "no
# available capacity" until the node restarts (regtest has no peers to drain
# it), so after two failed attempts the container is bounced —
# process-compose restarts it (availability.restart = always).
mine() {
    local tries
    for tries in 1 2 3 4 5; do
        if zebra_rpc generate "[$1]" >/dev/null; then
            return 0
        fi
        echo "  generate failed (attempt $tries/5)" >&2
        if [ "$tries" = "2" ]; then
            echo "  bouncing zebrad to clear gossip backpressure" >&2
            docker rm -f axion-zebrad >/dev/null 2>&1 || true
            sleep 3
            wait_for_zebra
        else
            sleep 5
        fi
    done
    return 1
}

chain_height() {
    zebra_rpc getblockchaininfo | jq -r '.blocks'
}

wait_for_port() {
    local host="$1" port="$2" what="$3" tries="${4:-120}"
    for _ in $(seq "$tries"); do
        if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
            exec 3>&- 3<&-
            return 0
        fi
        sleep 1
    done
    echo "timed out waiting for $what on $host:$port" >&2
    return 1
}

wait_for_zebra() {
    wait_for_port 127.0.0.1 18232 "zebrad RPC"
    for _ in $(seq 60); do
        zebra_rpc getblockchaininfo >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "zebrad RPC never became ready" >&2
    return 1
}

wait_for_file() {
    local path="$1" what="$2" tries="${3:-120}"
    for _ in $(seq "$tries"); do
        [ -s "$path" ] && return 0
        sleep 1
    done
    echo "timed out waiting for $what at $path" >&2
    return 1
}

# wallet <name> <subcommand...> — run zcash-devtool against a named wallet dir
wallet() {
    local name="$1"
    shift
    "$DEVTOOL" wallet -w "$WALLETS_DIR/$name" "$@"
}

# advice <name> <subcommand...> — the advice command family is top-level
advice() {
    local name="$1"
    shift
    "$DEVTOOL" advice -w "$WALLETS_DIR/$name" "$@"
}
