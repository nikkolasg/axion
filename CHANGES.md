# CHANGES

## Recovery demo removed (feature disabled in the wallet)

The recovery scene (`demo-serve-bob`, `demo-recover-oob`, `demo-recover-scan`)
is gone: the wallet now compiles `advice recover`/`redeliver` out of default
builds because seed-only recovery cannot honestly work until the Step 3
encrypted backup restores the per-contact index map — the demo only passed by
feeding the wallet an index a real user would have lost. Rather than let
people believe it works, the scripts were removed and the docs mark recovery
as disabled, with the dual-rail (chain scanning) as the recovery story for
now.

## Retention sweep, standalone rotation, unlinkability

Completed the last Step 1 protocol pieces. `advice flush --to <c>`: the
reconnection sweep (spec §1.3.2) — summarizes outbox state, surfaces
entries older than --overdue-secs, re-sends every pending envelope, and
collects late acks/rotations with the same signature-checked handler
`advice send` uses (hoisted to shared free functions, no duplication).
`advice rotate --to <c>`: recipient-initiated signed address rotation
(spec §1.3.5), applied by the sender on its next send/flush. Outbox
entries gained `sent_at` for overdue classification. New `rotate` message
(domain axion-rotate-v1, not channel-bound). Two-senders unlinkability is
a full demo (`demo-unlinkability` + third simplex instance + carol
wallet): Bob and Carol pay Alice on separate channels with distinct
subkeys/addresses; their stored records are asserted to share 0
identifiers. Live-verified: offline pay → pending → flush resolves +
rotates; proactive rotate → flush applies it; 0 common identifiers.

## Crypto-layer review hardening

Adversarial review of the signed-envelope/ack layer confirmed the ratchet
core (rotation requires a valid signature under the pairing-time key; the
five signing domains are unambiguous). Fixed from its findings: `advice
send` now signs with the pairing-time subkey index (was: CLI flag only —
silent ratchet death with non-default indexes); ratcheted/token addresses
are decoded against the wallet network before storage (a signed garbage
address can no longer wedge payments); txids normalized to lowercase at
the CLI boundary; `advice receive` requires -w like send; degraded
envelope authenticity (unsigned/unverifiable) is printed on stdout, not
just tracing. Accepted + documented: no ack counter (replay can roll the
ratchet back to an older peer-owned address), no state-file locking.

## Full cryptographic layer: signed envelopes, acks, address ratchet

Completed Step 1's crypto: pairing is bidirectional (recipient's token
carries a fresh per-contact diversified address, signature-covered;
sender replies with an identity-only token), advice envelopes are signed
by the sender's identity subkey (not channel-bound, so they survive
recovery re-delivery), and every verified advice is answered with a
signed ack that piggybacks the next fresh diversified address — the
sender rotates its per-contact working address only on a
signature-valid accepted-ack (spec §1.3.3). Outbox entries track
pending/acked/rejected. Live-verified: consecutive payments land on
different single-use addresses. Demo scripts pay via
`advice contact --to alice` (working_address). `advice send/receive/pair`
gained `--identity`; receive answers invalid advice with a signed
invalid-ack.

## Recovery protocol (spec §1.3.5 identity + §1.3.7 recovery)

Added the seed-derived identity layer and recovery re-delivery to the
devtool fork: pairing now hands the sender a signed identity token
(k_j from BLAKE2b(seed-root, j), ed25519); every sent advice is persisted
in the sender's outbox; `advice recover` (restored wallet) opens a new
channel, proves continuity via challenge/response, and chain-verifies every
re-delivered advice; `advice redeliver` is the sender side (proof matched
by pubkey, never by display name — fresh profiles rename on collision).
Demo scenes: demo-serve-bob / demo-recover-oob / demo-recover-scan.
Measured: 3 payments restored in 2.0s (226ms chain work) vs 2.2s full
rescan of 11.6k blocks. Behavior change: `advice pair`/`send` now require
`-w` (axion state lives in the wallet dir).

Post-review hardening (adversarial review findings): all token/proof
signatures are channel-bound (they cover a hash of the invitation link),
killing recovery-proof relay/MITM and cross-contact token replay; a key
already bound to another contact is refused; ambiguous pubkey matches at
redelivery are rejected; per-advice failures no longer abort a recovery
batch; state files are written atomically (temp+rename); contact names
containing quotes are refused by the simplex client (CLI injection).

## Initial demo implementation (Step 1 of the Axion OOB spec)

Built the whole regtest demo: devenv runs zebrad (Docker) + zainod (source) +
smp-server (Docker) + two headless simplex-chat instances; a zcash-devtool
fork (branch `axion-advice`, see its own CHANGES.md) adds
`advice pair/send/receive`; scripts `demo-setup` / `demo-noise` / `demo-pay` /
`demo-race` drive the story. Result: advice + one targeted decryption makes a
payment visible in ~100ms vs a full chain scan.

Hard-won environment knowledge (do not rediscover):
- Zebra's regtest default activates ONLY Canopy; NU5+ (Orchard) must be
  configured explicitly, and wallet-side activation heights
  (`configs/activation-heights.toml`) must match zebrad's or the validator
  rejects wallet txs. Env keys can't express `"NU6.1"` (dot), hence a mounted
  TOML + `ZEBRA_MINING__MINER_ADDRESS` env override.
- Zaino (0.4.3) needs zebra's indexer gRPC (`rpc.indexer_listen_addr`, port
  18230) — the official Docker image has it despite the Dockerfile default
  suggesting otherwise. Zaino also fails its initial sync on a genesis-only
  chain ("could not determine best chain"): mine one block first
  (run-zainod.sh does).
- Never export env vars starting with `ZAINO_` in the devenv: zainod treats
  them as config overrides and rejects unknown keys.
- devtool sync queries a third pool (Ironwood) that zaino rejects with
  InvalidArgument; the fork treats that as "no subtrees" (sync.rs).
- Funding trick: zebra supports shielded coinbase — set miner_address to an
  Orchard unified address and block rewards land directly shielded. This
  avoids the transparent shield step entirely AND fixes "Unable to compute
  anchor" (empty note commitment tree) at the root.
- simplex-chat CLI is not in nixpkgs and nixpkgs' simplexmq is ancient; the
  pinned GitHub release binary + autoPatchelf works. Headless first run needs
  `--create-bot-display-name`, otherwise it blocks on a TTY prompt.
- Zaino reports a mempool transaction's GetTransaction "height" as the
  current tip (not 0) until it indexes the block, so a height read right
  after mining can be off by one. `advice send` therefore only trusts a
  mined height once zaino shows at least one block on top of it. (The
  recipient's height-mismatch rejection caught this live.)
- After mining thousands of regtest blocks, zebra's block-gossip channel
  fills ("failed to send mined block to gossip task: no available capacity")
  and never drains (no peers); every later `generate` fails until zebrad
  restarts. `mine()` in lib.sh bounces the container automatically.
- simplex-chat delivers events only to WebSocket clients connected at
  arrival time: an orphaned `advice receive` from an aborted run swallows
  the advice meant for the current listener (demo-race now kills orphans
  first), and advice sent while no listener is attached is not replayed.
