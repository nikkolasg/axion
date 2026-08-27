#!/usr/bin/env bash
# devenv process: self-hosted SimpleX SMP relay via the pinned official image.
#
# The image's entrypoint initializes the server on first run (needs ADDR;
# WEB_MANUAL=1 keeps it a plain SMP server on 5223 without the web console
# cert paths). Certs/config persist in run/smp/etc, so the address
# fingerprint is stable across restarts. The smp:// client address is
# derived from the persisted CA fingerprint file.
set -euo pipefail
: "${DEMO_ROOT:?}" "${RUN_DIR:?}"

SMP_IMAGE="simplexchat/smp-server:v6.5.2"
SMP_ETC="$RUN_DIR/smp/etc"
SMP_VAR="$RUN_DIR/smp/var"
ADDRESS_FILE="$RUN_DIR/smp/address"

mkdir -p "$SMP_ETC" "$SMP_VAR"

# Publish the smp:// address once the fingerprint exists (created by the
# entrypoint's init on first start). Runs alongside the server below.
(
    for _ in $(seq 120); do
        if [ -s "$SMP_ETC/fingerprint" ]; then
            printf 'smp://%s@127.0.0.1' "$(cat "$SMP_ETC/fingerprint")" > "$ADDRESS_FILE"
            echo "SMP server address: $(cat "$ADDRESS_FILE")"
            exit 0
        fi
        sleep 1
    done
    echo "fingerprint never appeared in $SMP_ETC" >&2
) &

docker rm -f axion-smp >/dev/null 2>&1 || true
exec docker run --rm --name axion-smp \
    -p 127.0.0.1:5223:5223 \
    -e ADDR=127.0.0.1 \
    -e WEB_MANUAL=1 \
    -v "$SMP_ETC:/etc/opt/simplex" \
    -v "$SMP_VAR:/var/opt/simplex" \
    "$SMP_IMAGE"
