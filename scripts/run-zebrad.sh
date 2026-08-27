#!/usr/bin/env bash
# devenv process: zebrad on regtest, via the pinned official Docker image.
set -euo pipefail
: "${DEMO_ROOT:?}" "${RUN_DIR:?}"

ZEBRA_IMAGE="zfnd/zebra:6.2.2"
mkdir -p "$RUN_DIR/zebra-state"

# demo-setup writes Bob's transparent address here so coinbase funds him;
# until then the placeholder in the config file is used.
MINER_ADDR=""
if [ -s "$RUN_DIR/miner-address" ]; then
    MINER_ADDR=$(cat "$RUN_DIR/miner-address")
fi

docker rm -f axion-zebrad >/dev/null 2>&1 || true

args=(
    --rm --name axion-zebrad
    -p 127.0.0.1:18232:18232
    -p 127.0.0.1:18230:18230
    -v "$RUN_DIR/zebra-state:/home/zebra/.cache/zebra"
    -v "$DEMO_ROOT/configs/zebrad-regtest.toml:/etc/zebrad/zebrad.toml:ro"
    -e CONFIG_FILE_PATH=/etc/zebrad/zebrad.toml
)
if [ -n "$MINER_ADDR" ]; then
    args+=(-e "ZEBRA_MINING__MINER_ADDRESS=$MINER_ADDR")
fi

exec docker run "${args[@]}" "$ZEBRA_IMAGE"
