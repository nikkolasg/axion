#!/usr/bin/env bash
# devenv process: Zaino indexer (built from source by demo-setup).
set -euo pipefail
: "${DEMO_ROOT:?}" "${RUN_DIR:?}"
source "$DEMO_ROOT/scripts/lib.sh"

ZAINOD="$DEMO_ROOT/zaino/target/release/zainod"
if [ ! -x "$ZAINOD" ]; then
    echo "zainod not built yet — run demo-setup first (builds zaino); waiting..." >&2
    while [ ! -x "$ZAINOD" ]; do sleep 5; done
fi

wait_for_zebra

# Zaino's initial sync cannot determine a best chain on a genesis-only
# regtest ("ReorgFailure"); make sure at least one block exists.
if [ "$(chain_height)" = "0" ]; then
    echo "empty regtest chain — mining the first block for zaino"
    mine 1
fi

mkdir -p "$RUN_DIR/zaino/db"
export ZAINO_STORAGE__DATABASE__PATH="$RUN_DIR/zaino/db"

exec "$ZAINOD" start --config "$DEMO_ROOT/configs/zaino-regtest.toml"
