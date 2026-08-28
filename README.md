# 🛰️ Axion Step 1 — out-of-band payment advice on Zcash

[![CI](https://github.com/nikkolasg/axion/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nikkolasg/axion/actions/workflows/ci.yml)

> ⚠️ **Experimental research prototype — regtest only, not audited, not for
> mainnet funds.** This demonstrates Step 1 of the Axion spec end-to-end on a
> local Zcash network. It is a proof of concept meant to be read and poked at,
> not a shipping product.

## 🎯 What this is

After a sender broadcasts an ordinary shielded transaction, it pushes a small
signed **advice** message — `{txid, height, pool, output_index}` — to the
recipient over a self-hosted **SimpleX** channel. The recipient then:

- **Syncs like any normal wallet** — the same `GetBlockRange` requests, so the
  indexer never learns which transaction is hers — but uses the advice to
  **trial-decrypt the advised block first**, surfacing the payment before the
  rest of the scan finishes.
- **Trusts nothing in the message.** Every field is verified against chain data
  she fetches herself, with her own viewing keys.

Everything is layered on top of ordinary shielded transactions, so the chain is
always the backstop: if the channel dies, normal scanning still finds the
payment, and funds are recoverable from the seed alone (the **dual-rail**
invariant). No consensus change.

This is the delivery channel Tachyon will need, shipped early under a reason
users already want — faster wallets. The [ONEPAGER.md](ONEPAGER.md) makes that
case; this README is the engineering front door.

📚 **Docs:** [ONEPAGER.md](ONEPAGER.md) (the pitch and the measured numbers) ·
[TECHNICAL.md](TECHNICAL.md) (protocol reference: message formats, signing,
hashes, the counter, the channel command set, anonymity) ·
`../zcash_oob_identity_spec.md` (the design spec this implements).

## 🧱 The stack

| Component | What | How it runs |
|---|---|---|
| zebrad | regtest chain, instant `generate` mining, shielded coinbase | Docker `zfnd/zebra:6.2.2` (devenv process) |
| zainod | lightwalletd-protocol indexer over zebrad | built from source (`zaino/`, devenv process) |
| smp-server | self-hosted SimpleX relay, localhost-only | Docker `simplexchat/smp-server:v6.5.2` (devenv process) |
| simplex-chat ×3 | headless CLI per wallet (alice/bob/carol), WebSocket JSON API on :5226/:5227/:5228 | pinned release binary, nix-patched (devenv processes) |
| zcash-devtool | CLI light wallet — **the fork with the new `advice` commands** | built from source (`zcash-devtool/`, branch `axion-advice`) |

Wallets: `bob` (sender; the regtest miner pays shielded coinbase straight to his
Orchard address), and `alice-oob` / `alice-scan` — the **same seed and birthday**
restored twice, so the advice-path-vs-full-scan race is honest.

## 🚀 Install & run

Prerequisites: [`devenv`](https://devenv.sh) + Nix, and Docker (for zebrad and
the SimpleX relay). The wallet and indexer are **git submodules**
(`zcash-devtool` on branch `axion-advice`, and `zaino`), so clone recursively;
everything else is fetched or built by the setup step.

```sh
git clone --recurse-submodules https://github.com/nikkolasg/axion.git
cd axion            # (already cloned? run: git submodule update --init --recursive)
devenv up -d        # start zebrad, zainod, smp-server, 3× simplex-chat (background)
devenv shell
demo-setup          # checkout submodules, build wallet + indexer, create wallets, fund Bob, pair
demo-noise          # one-time: manufacture chain history (QUICK=1 for a fast variant)
demo-race           # the headline: advice + targeted decrypt vs full scan, side by side
```

Other scenarios (each is a script under `scripts/`):

| Command | Scene |
|---|---|
| `demo-pay` | Send one paid-and-advised payment (`NO_ADVICE=1` skips the advice). |
| `demo-race` | Fast-sync head-to-head vs a vanilla wallet; ends with the relay-killed fallback. |
| `demo-unlinkability` | Two senders paying one recipient — zero shared identifiers. |
| `demo-scaling` | The timing numbers at ~3.6k / 10k outputs and a ~1-month gap. |

There is deliberately **no recovery scenario** — see the disabled-recovery note
in [Notes & quirks](#-notes--quirks). Video-friendly single-window pieces exist
too (`demo-pair-*`, `demo-watch-*`) for recording each actor in its own window.

Ports (all localhost-only): zebrad RPC 18232, zebrad indexer gRPC 18230, zainod
gRPC 8137, smp-server 5223, simplex WS alice 5226 / bob 5227 / carol 5228.

## 🔧 What changed, and where it would live

**All new code is in the `zcash-devtool` fork on branch `axion-advice`** (under
`src/commands/advice/`, `src/commands/advice.rs`, `src/simplex.rs`). The other
repos are **unmodified pinned dependencies** — the demo uses zcash-devtool as a
convenient harness, but in a production Zcash stack the pieces below would move
into their natural homes. This table is the porting map.

| Capability | Where it is now | Where it would belong |
|---|---|---|
| **Identity & key derivation** — seed → BLAKE2b root → per-contact Ed25519 subkeys, domain-separated signing | `advice/identity.rs` | Beside ZIP-32 derivation in **`zcash_keys` / librustzcash** — it is seed-derived key material. |
| **Wire protocol** — message formats, validation, the ack replay counter | `advice.rs`, `advice/store.rs` | A **shared Axion protocol crate** (versioned, transport-independent messages). |
| **Private receive** — the "priority peek" (`scan_block` on one cached block) + shared sync primitives | `advice/receive.rs`, `helpers/scan.rs`, `helpers/tx_fetch.rs` | **`zcash_client_backend`** — it already owns `scan_block` / `scan_cached_blocks`; the peek is a thin addition to the scan/data-api layer. |
| **SimpleX transport** — async WebSocket client for the simplex-chat CLI | `simplex.rs` | Wallet app / a **transport crate**; deliberately out of consensus/core. |
| **Persistent state** — peers, outbox, index counter | `advice/store.rs` (JSON files) | The **wallet database** (`zcash_client_sqlite`) as tables. |
| **Ironwood (NU6.3) support** — subtree roots, output decoding, one indexer-compat hunk | consumed from the pinned **librustzcash** rev; compat hunk in `wallet/sync.rs` | Upstream **librustzcash / zaino** (already largely there at the pinned rev). |

The `advice` command family — **`pair`, `send`, `receive`, `flush`** (plus
`redeliver`/`recover`, compiled out behind the `unstable-recovery` feature —
see Notes) — ships with **49 unit tests** and has been through several
adversarial code reviews (findings on channel binding, replay, key handling,
and per-contact key reuse all fixed). See [TECHNICAL.md](TECHNICAL.md) for
exactly what each does on the wire.

## 🔭 Extensions

Directions that would extend the demo, kept separate from what it does today
(the broader roadmap is in [ONEPAGER.md](ONEPAGER.md#-future-work)):

- **Transport-level offline delivery.** `advice receive` currently only catches
  messages pushed live (see Notes below). A dedicated store-and-forward
  mailbox — for example a [Nym](https://nym.com) mailbox — would hold advice for
  an offline recipient and hand it over on reconnect, without relying on the
  sender to re-send it. This is the transport-layer counterpart to the
  application-level re-send (`advice flush`) the demo already provides.

## 📝 Notes & quirks

- **Payments in the demo are Orchard (NU5), not Ironwood.** Ironwood (NU6.3) is
  handled in the code but not activated in this regtest — the pinned zebra image
  predates it. (Regtest activation heights are configured in `configs/`.)
- The OOB path yields a **detected, chain-verified** payment (time-to-visibility,
  what the spec promises). Making the note immediately *spendable* additionally
  needs commitment-tree data from the unmodified background scanner.
- **Two kinds of replay — the demo provides one.** *Application-level* re-send
  works: `advice flush` re-sends un-acked advice on reconnection, so a payment
  notice is never silently dropped. What is not wired up is *transport-level*
  offline delivery: `advice receive` only catches messages pushed live over the
  WebSocket, so it will not re-read an advice that arrived while it was not
  listening. A store-and-forward mailbox would close that — see
  [Extensions](#-extensions).
- **Seed-only recovery is DISABLED for now** (no `advice recover`/`redeliver`
  commands, no recovery demo). The channel-level flow — prove your seed-derived
  identity to a contact, have it replay its outbox — is implemented and
  reviewed, but it cannot honestly work *seed-only* yet: with per-contact keys,
  a wallet restored from its seed alone does not know which subkey index each
  contact holds, and restoring that map is exactly what the future **Step-3
  encrypted backup** provides. Rather than ship a command that only works when
  the operator supplies state a real user would have lost, the code is compiled
  out behind the `unstable-recovery` cargo feature until the backup exists.
  **This costs nothing today:** every advised payment is an ordinary shielded
  tx, so a wallet restored from seed still finds all its funds by normal
  scanning (the dual rail). Durable encrypted recovery only becomes essential
  for **Tachyon**, once the chain stops carrying the payment data.
- All demo state lives in `run/` (gitignored). For a **factory reset**, run
  **`demo-reset`** — it stops the stack and wipes `run/` as a unit (chain,
  wallets, and relay identity together), then `devenv up -d && demo-setup`
  starts a clean slate.
