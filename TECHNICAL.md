# Axion Step 1 — Technical Protocol Reference

> ⚠️ **Experimental research prototype.** This document describes what the demo
> code actually does, byte for byte. It is an implementation reference, not a
> ratified standard. The design intent lives in the Axion spec
> (`../zcash_oob_identity_spec.md`); the run guide lives in the
> [README](README.md); the pitch and measured numbers live in
> [ONEPAGER.md](ONEPAGER.md). Nothing here has been security-audited, and it
> targets regtest only.

Axion Step 1 is an **out-of-band payment-advice layer** for Zcash. After a
sender broadcasts an ordinary shielded transaction, it pushes a small signed
*advice* message to the recipient over a SimpleX channel telling her exactly
where her note is (`txid`, `height`, `pool`, `output_index`). The recipient
confirms the payment against chain data she fetches herself — never trusting the
sender — and surfaces it without a full rescan. The chain is always the
backstop: every advised payment is a normal shielded transaction, discoverable
by scanning from the seed alone.

This document specifies the wire formats, the cryptography, the message flows a
wallet can drive on the channel, the on-disk state, and the anonymity
properties. All of it is implemented in the `zcash-devtool` fork on branch
`axion-advice`, under `src/commands/advice/`, `src/commands/advice.rs`, and
`src/simplex.rs`.

## Contents

- [1. Identity and key derivation](#1-identity-and-key-derivation)
- [2. Message catalog](#2-message-catalog)
- [3. Signing inputs](#3-signing-inputs)
- [4. Addresses: per-contact keys and the ack ratchet](#4-addresses-per-contact-keys-and-the-ack-ratchet)
- [5. The replay counter](#5-the-replay-counter)
- [6. Channel command set and message flows](#6-channel-command-set-and-message-flows)
- [7. On-disk state](#7-on-disk-state)
- [8. Receive-side verification and the dual rail](#8-receive-side-verification-and-the-dual-rail)
- [9. Anonymity analysis](#9-anonymity-analysis)
- [10. What is not protected](#10-what-is-not-protected)

---

## 1. Identity and key derivation

Every party's long-term identity is derived from its BIP-39 wallet seed, the
same seed `wallet init` produces (BIP-39 with an empty passphrase). No identity
key material is ever stored: it is re-derived on demand, so a seed-only restore
reconstructs the same identity. (`src/commands/advice/identity.rs`)

The hash is **BLAKE2b-256** with a domain-separating *personalization* string:

```
root = BLAKE2b-256(personal = "Zcash_AxionRoot", seed)
k_j  = BLAKE2b-256(personal = "Zcash_AxionSubk", root || LE32(j))
```

- `root` is the secret identity root.
- `k_j` is the per-contact subkey seed at index `j`, used directly as the seed
  of an **Ed25519** signing key (`ed25519-zebra`). `K_j = public(k_j)` is the
  32-byte verification key shared at pairing.
- Both steps are one-way: a party holding `K_j` learns nothing about `root` or
  any sibling `k_i`.
- Intermediates (`root`, the derivation input, `k_j`) are zeroized after use;
  the seed is handled as a `secrecy::SecretVec`.

A third personalization derives the **channel binding**, a hash of the SimpleX
invitation link that created the channel a message travels on:

```
link_binding = BLAKE2b-256(personal = "Zcash_AxionLink", invitation_link)
```

Both ends of a channel know the link (one minted it, the other joined it), and a
relay cannot make two different links hash alike — so binding a signature to
`link_binding` makes it worthless if replayed onto any other channel.

| Personalization | Input | Output |
|---|---|---|
| `Zcash_AxionRoot` | seed | identity root secret |
| `Zcash_AxionSubk` | `root ‖ LE32(j)` | per-contact Ed25519 key seed `k_j` |
| `Zcash_AxionLink` | invitation link | 32-byte channel binding |

### How these pieces are used: the pairing flow

Concretely, when Alice adds Bob as a contact (she is the *invite* side):

1. **Alice derives, from her seed alone** — no interaction with Bob — a fresh
   per-contact index `j`, its identity subkey `K_j = public(k_j)`, and a fresh
   diversified receiving address `addr_j`.
2. **Alice opens a channel:** a SimpleX invitation link. This link is the one
   artifact that must reach Bob out-of-band, and it is exactly what a **QR code
   carries** — shown in person, printed on an invoice or payment request, or
   sent over any messenger they already share. It is short-lived and single-use.
3. **Bob joins the link** → the SimpleX channel is established. Both ends now
   know the link, so both can compute `link_binding = H(link)`.
4. **Alice sends her signed `token`** `{ j, K_j, addr_j, sig }` over the
   channel. `sig` is her self-signature covering `link_binding` (§3), so the
   token is worthless if a relay or a MITM replays it onto any other channel.
5. **Bob verifies** `sig` against `K_j` and the link, then stores `K_j` (to
   check Alice's future advice/acks) and `addr_j` (the address he now pays). Bob
   may reply with an identity-only token of his own, so Alice can likewise
   verify his messages.

From then on **no QR is needed**: every later message — advice, acks,
recovery — rides the open channel. (In the Axion spec the token bundles the
endpoint too, so a single QR conceptually carries everything; the demo splits it
— invitation link to establish the channel, token over the channel — with the
same channel-bound-identity property.) The exact message exchange is in
[§6](#6-channel-command-set-and-message-flows).

---

## 2. Message catalog

Every message is a single UTF-8 JSON object, sent as one SimpleX text message
(pretty-printed here for readability — on the wire it is compact single-line).
All carry `v` (protocol version, currently `1`) and `type`. Hex fields are
lowercase; each placeholder states its **byte** length (one byte = two hex
chars), and §3 gives the exact signed-byte layouts. Structs are defined in
`src/commands/advice.rs`; validators (`validate_*`) reject anything malformed
before it is trusted.

| `type` | Direction | Purpose |
|---|---|---|
| `token` | pairing, both ways | Identity token: verification key (+ optional pay-to address) |
| `advice` | sender → recipient | "Your note is at (txid, height, pool, output_index)" |
| `ack` | recipient → sender | Acknowledge one advice; carry the next fresh address |
| `advice_batch` | sender → recovered peer | A chunk of advice envelopes (recovery re-delivery) † |
| `redelivery_done` | sender → recovered peer | End-of-batch marker with a count † |
| `recovery_challenge` | sender → recovered peer | Random nonce; proves seed ownership in the recovery handshake ([§6](#6-channel-command-set-and-message-flows)) † |
| `recovery_proof` | recovered peer → sender | Signature over the nonce with the seed-derived key ([§6](#6-channel-command-set-and-message-flows)) † |

† The four recovery messages are specified and implemented, but **disabled in
default builds** (compiled out behind the wallet's `unstable-recovery` cargo
feature) — see the status note in [§6](#6-channel-command-set-and-message-flows).

### `token`

```json
{
  "v": 1,
  "type": "token",
  "j": 0,
  "pubkey": "<32-byte key, hex>",
  "address": "<unified address>",
  "sig": "<64-byte sig, hex>"
}
```

`j` is the signer's subkey index; `pubkey` is `K_j`; `address` is optional (the
invite side carries a freshly minted diversified address to be paid, identity-
only reply tokens omit it — an empty string is rejected, it must be absent);
`sig` is the self-signature (§3).

### `advice`

```json
{
  "v": 1,
  "type": "advice",
  "txid": "<32-byte txid, display-order hex>",
  "height": 11376,
  "pool": "orchard",
  "output_index": 1,
  "sig": "<64-byte sig, hex>"
}
```

`txid` is display-order hex (byte-reversed relative to the internal encoding);
`pool` ∈ {`sapling`, `orchard`, `ironwood`}; `sig` (a 64-byte Ed25519
signature) is optional — an unsigned envelope is accepted with a warning, since
chain verification governs whether the payment is real (§8).

### `ack`

```json
{
  "v": 1,
  "type": "ack",
  "txid": "<32-byte txid, display-order hex>",
  "status": "accepted",
  "next_address": "<unified address>",
  "counter": 7,
  "sig": "<64-byte sig, hex>"
}
```

`status` ∈ {`accepted`, `invalid`}; an accepted ack carries the recipient's
**next** fresh address (the ratchet, §4), an invalid ack carries an empty one;
`counter` is the replay guard (§5); `sig` is optional but, once a peer key is
stored, an unsigned or bad-signature ack is refused (it drives a state change).

### `advice_batch`, `redelivery_done`

```json
{
  "v": 1,
  "type": "advice_batch",
  "advices": [ <advice object>, <advice object>, ... ]
}
```

```json
{
  "v": 1,
  "type": "redelivery_done",
  "count": 42
}
```

Recovery re-delivery packs up to **40** advice envelopes per batch (each SimpleX
message is a full client/relay round-trip, ~0.2–0.3 s on the reference stack),
then a `redelivery_done` with the total. Each entry is validated as strictly as
a standalone `advice`.

### `recovery_challenge`, `recovery_proof`

```json
{
  "v": 1,
  "type": "recovery_challenge",
  "nonce": "<32-byte nonce, hex>"
}
```

```json
{
  "v": 1,
  "type": "recovery_proof",
  "j": 0,
  "pubkey": "<32-byte key, hex>",
  "sig": "<64-byte sig, hex>"
}
```

`nonce` is 32 random bytes (`OsRng`). The proof signs the nonce bound to the new
channel's link (§3); the sender matches `pubkey` against the key it stored at
pairing (by key value, never display name). The full challenge → proof →
re-delivery handshake — how a restored wallet proves seed ownership and pulls
its history back — is in [§6](#6-channel-command-set-and-message-flows).

---

## 3. Signing inputs

Signatures are Ed25519 over a domain-separated byte string. The **domain**
(a distinct ASCII prefix per message kind) means a signature made in one context
never verifies in another, even over identical payload bytes. Some inputs are
additionally **channel-bound** (include `link_binding`): those are worthless if
replayed on a different channel. Advice and acks are deliberately *not*
channel-bound — they must stay verifiable when re-delivered over a fresh channel
after recovery; they are properties of the payment relationship, not the
transport (the channel's own double ratchet still authenticates each hop).

All multi-byte integers are little-endian. `txid` is the 32-byte **internal**
order (not display hex).

| Domain prefix | Covers | Channel-bound? |
|---|---|---|
| `axion-token-v1` | `LE32(j) ‖ pubkey(32) ‖ link(32) ‖ address_bytes` | ✅ yes |
| `axion-advice-v1` | `txid(32) ‖ LE32(height) ‖ pool_byte(1) ‖ LE32(output_index)` | ❌ no |
| `axion-ack-v1` | `txid(32) ‖ status_byte(1) ‖ LE64(counter) ‖ next_address_bytes` | ❌ no |
| `axion-recovery-v1` | `nonce(32) ‖ link(32)` | ✅ yes |

`pool_byte`: sapling = 0, orchard = 1, ironwood = 2.
`status_byte`: invalid = 0, accepted = 1.

`address_bytes` / `next_address_bytes` are the UTF-8 of the address string
(empty slice when absent — this keeps pre-address tokens and empty-address acks
verifiable). Because the address is *inside* the signed bytes, a relay cannot
swap the pay-to address inside an otherwise valid token or ack.

Signature policy on receipt:

- **Token / recovery proof** — must verify against a stored/presented key and
  the channel link, or the message is rejected outright.
- **Advice** — signature + stored peer key must verify (hard reject on
  mismatch); a signature with no stored key, or no signature at all, is accepted
  with a warning (chain verification still governs). The authenticity outcome
  (`Authenticated` / `Unverifiable` / `Unauthenticated`) is printed so scripts
  can tell them apart.
- **Ack** — drives a state change (the address ratchet), so when a peer key is
  stored, both a bad signature and a missing one make the ack unusable and it is
  ignored; without a stored key it is accepted with a warning.

---

## 4. Addresses: per-contact keys and the ack ratchet

**A distinct identity key per contact.** Pairing allocates a fresh subkey index
`j` per contact from a persisted counter (`axion-next-index.json`), so two
senders paying one recipient store two different verification keys and their
leaked records share no common identifier (spec §1.5 scenario 3). The counter
starts at a random offset the first time it is created, so a seed-only recovery
(which has no record of the indexes it issued) does not reissue an old index;
`--index` on `advice pair` overrides allocation only to reproduce a known
pairing. (`store::allocate_identity_index`)

**A fresh receiving address per payment (the ratchet, spec §1.3.3).** A sender
cannot mint addresses for the recipient — that needs her keys — so she supplies
them on messages she already sends. The invite token carries the first
diversified address; every `accepted` ack carries the *next* one, and the sender
always pays the newest address it holds (`working_address` in the peers file).
Addresses are minted with the same machinery as `wallet generate-address`
(`get_next_available_address`). A signed-but-undecodable address never wedges the
sender: it keeps paying the current address and warns.

On-chain, note commitments hide the receiving address, so even repeated payments
to one address are unlinkable on the ledger; the fresh-address-per-payment
policy limits the blast radius if one payment's details ever surface off-chain
(a dispute, an invoice, a leaked message).

---

## 5. The replay counter

An ack is signed but not channel-bound, so on its own a captured, still-valid ack
could be replayed later (e.g. onto a fresh post-recovery channel, or by a
compromised endpoint) to roll the sender's `working_address` **back** to an
older address — reusing an address and re-linking payments on-chain. Funds are
never at risk (all addresses are the recipient's), but the unlinkability the
ratchet buys would be lost.

The counter closes this:

- Each ack carries a per-relationship monotonic `counter` **inside its signed
  bytes** (§3), so it cannot be re-stamped.
- The recipient advances the sequence on every ack it sends
  (`store::next_outgoing_counter`, persisted as `next_ack_counter`).
- The sender, **only after the signature verifies**, accepts an ack whose
  counter is strictly greater than the last it accepted, and advances its
  high-water mark (`store::accept_incoming_counter`, persisted as
  `last_ack_counter`). A stale or equal counter is ignored; a forged counter on
  a bad-signature message never reaches the check, so it cannot poison the
  high-water mark and DoS legitimate acks.

Where there is no stored peer key (an unverifiable relationship), neither the
signature nor the counter is enforced — consistent, since an attacker who could
forge the whole ack there gains nothing from the counter.

---

## 6. Channel command set and message flows

A wallet drives the channel through four `advice` subcommands (`pair`, `send`,
`receive`, `flush`) plus the disabled recovery pair. Each is a small
state machine over the message types in §2; taken together they are the full set
of operations a user can issue on a SimpleX channel, including the **history
playback** used after a seed-only restore.

### `advice pair` — establish the channel

`--mode invite` mints an invitation link (over the local relay), waits for the
peer to connect, and — with `--identity` — mints a fresh address and sends a
signed `token` carrying it, then waits briefly for the peer's reply token.
`--mode join` consumes a link, connects, sends its own identity-only `token`,
and waits for the inviter's. Each side stores the other's token (`save_peer`),
refusing a key already bound to a different contact. Pairing is the only step
that needs a QR/link exchange; every later message rides the open channel.

### `advice send` / `advice receive` + ack — the payment path

```
sender: broadcast shielded tx  →  find own Outgoing output (own viewing keys)
        →  build+sign advice {txid,height,pool,output_index}
        →  send over SimpleX  →  append to outbox (pending)
        →  wait up to --ack-timeout for an ack

recipient: wait for an "advice" message  →  validate (untrusted)
        →  check signature policy  →  verify against chain (§8)
        →  mint next address  →  send signed accepted ack {…, next_address, counter}

sender: on accepted ack → mark outbox acked, ratchet working_address forward
```

A rejected payment (chain verification fails) yields an `invalid` ack and a
non-zero exit on the recipient.

### `advice flush` — retention sweep (spec §1.3.2)

Prints an outbox summary, flags entries unacknowledged past `--overdue-secs` as
`OVERDUE`, re-sends every `pending` envelope verbatim (signature included), and
collects any late acks — so a recipient who was offline catches up on
reconnection. The sender keeps each advice in the outbox until acknowledged; the
same ack that resolves it also advances the ratchet, so retention and rotation
ride one message.

### `advice redeliver` / `advice recover` — seed-only history playback (spec §1.3.7, **disabled**)

This is the recovery design: a wallet restored from only its seed re-obtains
its entire payment history from a contact, with no chain rescan. It is
implemented and reviewed but **compiled out of default builds** — see the
status note below for why.

```
recovered wallet (recover): publish a fresh invitation link
contact (redeliver):        join it, send recovery_challenge {nonce}
recovered wallet:           sign nonce ⊕ link with the seed-derived key
                            → recovery_proof {j, pubkey, sig}
contact:                    match pubkey to a stored peer (by key, not name),
                            verify sig against nonce+link
                            → replay outbox as advice_batch chunks (≤40 each)
                            → redelivery_done {count}
recovered wallet:           validate each envelope, chain-verify each payment,
                            print RECOVERY COMPLETE + split timing
```

The proof is channel-bound, so it cannot be relayed onto another channel. The
identity key the recovered wallet signs with is the same `K_j` the contact
stored at first pairing — that continuity is what proves "same person."

**Status — disabled until the Step 3 encrypted backup exists.** With
per-contact identity indices (§4), a wallet restored from its seed alone does
not know which index `j` it used for a given contact, so it cannot reproduce
the right `K_j` unaided — the flow only works when the operator supplies the
index out of band, which a real user after device loss cannot do. Rather than
ship a command people would reasonably believe works seed-only, the two
subcommands and the four recovery messages are **compiled out behind the
wallet's `unstable-recovery` cargo feature** (the code and its tests remain in
the tree; the protocol above is the reference for when the index↔contact map
becomes restorable via the Step 3 encrypted backup). **This is not
load-bearing in Step 1:** every advised payment is an ordinary shielded
transaction, so a wallet that cannot re-establish the channel still finds all
its payments by normal scanning from the seed (the dual rail, §8). Durable
encrypted recovery only becomes essential for **Tachyon**, once the chain no
longer carries the payment ciphertexts.

---

## 7. On-disk state

Three JSON files in the wallet directory, written atomically (write-then-rename).
No private key material is stored — only public keys, addresses, and metadata.
Loaders are backward-compatible: fields added over time are optional and old
files still load.

| File | Shape | Notes |
|---|---|---|
| `axion-peers.json` | `contact → { j, pubkey, working_address?, my_index?, next_ack_counter?, last_ack_counter? }` | Identity + relationship state. One key ↔ one contact (enforced). |
| `axion-outbox.json` | `contact → [ { envelope, status, sent_at? } ]` | `status` ∈ pending/acked/rejected; re-delivery replays all statuses. |
| `axion-next-index.json` | a single `u32` | Next identity index to allocate; starts at a random offset. |

---

## 8. Receive-side verification and the dual rail

The recipient never trusts the advice. Every field is checked against chain data
fetched from her own indexer connection, with her own viewing keys. A tampered
height, an unknown txid, a transaction that pays someone else, or a server
returning a different transaction all end in `ADVICE REJECTED` and a non-zero
exit.

There are two receive modes:

- **Private (default).** Make the same block-download requests a normal syncing
  wallet makes — subtree roots, chain tip, and an ordinary full-range
  `GetBlockRange` over the scan gap — caching blocks in `FsBlockDb`. Then,
  purely locally: a **priority peek** trial-decrypts *only the advised block*
  (via `scan_block`, no note-commitment-tree state, no network) for instant
  visibility, followed by a full `scan_cached_blocks` over the whole gap so
  nothing else is missed and the advised note is durably stored with its
  witness. **The indexer never learns which transaction or note is hers** — it
  sees the request set of an ordinary sync. (This is not a byte-identical
  fingerprint: the downloads are front-loaded rather than interleaved with
  scanning, and the transparent-UTXO refresh a full sync performs is skipped, so
  an indexer can still tell a receive from a sync — it just never learns the
  note.)
- **`--fast-sync` (opt-in, lower privacy).** Fetch only the advised transaction
  with `GetTransaction` and run one targeted trial decryption, skipping the
  scan. Faster, but reveals the exact txid to the indexer. The background scanner
  backstops completeness.

**The dual rail.** Every advised payment is an ordinary shielded transaction. If
the relay is down, the advice is lost, or the recipient never adopted Axion, a
normal scan still finds the payment and funds are recoverable from the seed
alone. The scanner is unmodified; Axion is an accelerator layered on top, never a
new source of truth, and needs no consensus change.

---

## 9. Anonymity analysis

Anonymity is protected at three independent layers, stated with their honest
residual leaks.

- **On the chain — per-sender, per-payment addresses.** Each contact is paid at a
  different diversified address (distinct subkey index) and a fresh one per
  payment (the ratchet). Records leaked from two senders share no common value,
  and it costs nothing: every such address is found with the recipient's single
  viewing key. *Residual:* none beyond what Zcash shielded transactions already
  leak.
- **At the relay — per-pair queues.** SimpleX has no user accounts; traffic is
  end-to-end encrypted with forward secrecy; each sender-recipient pair gets its
  own queues on servers the recipient chooses. The relay cannot read content,
  cannot forge a payment notice (every message is signed), and stores no
  long-term identity. *Residual:* it does see that messages on one queue belong
  to one relationship, and network-level metadata (IP, timing, message sizes)
  can correlate traffic. Application messages are **not padded** and vary by type
  and outcome, so the relay-visible size distribution is masked only by SimpleX's
  own transport padding. Addressed later with Tor, uniform message sizes, and
  timing jitter — not by this step.
- **At the indexer — no targeted lookup (default path).** The private receive
  path issues the block requests of an ordinary sync and never asks for a
  specific transaction, so the indexer cannot tell which payment is hers. Asking
  for it directly (the `--fast-sync` opt-in) would be nearly as revealing as
  handing over her viewing key, which is why it is opt-in and clearly labelled.
  *Residual:* the request cadence and the missing transparent-UTXO refresh let an
  indexer distinguish a receive from a full sync — it learns *that* an advice is
  being processed, never *which note*.

The identity layer's own hygiene: keys are seed-derived and one-way, no private
material is stored, all signatures are domain-separated, and the acks/tokens that
drive state changes are counter- or channel-bound against replay.

---

## 10. What is not protected

- **Network metadata** (IP, timing, unpadded message sizes) — see §9; mitigated
  later by Tor + uniform sizes + jitter, not by Step 1.
- **The relay learns a relationship exists** on a given queue (not who, not
  what).
- **`--fast-sync` reveals the txid** to the indexer, by design.
- **Seed-only recovery is disabled** (§6). Re-establishing a per-contact
  identity from the seed alone needs the index restored — a Step 3
  encrypted-backup capability — so the `recover`/`redeliver` commands are
  compiled out (`unstable-recovery` feature) until that exists. It is not
  load-bearing: the chain still finds every payment by normal scanning, and this
  only becomes essential under Tachyon.
- **Not audited.** The code has unit tests and has been through adversarial
  reviews, but no formal security audit. Regtest only. Do not point it at
  mainnet funds.
- **Post-quantum:** identity uses Ed25519; the format is versioned, so a PQ
  signature scheme is a drop-in follow-up.
