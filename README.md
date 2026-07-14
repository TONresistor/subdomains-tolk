# TON Subdomains

Anyone who owns a `.ton` domain can open their own subdomain registry. Each subdomain is a tradeable **TEP-62 NFT** that resolves on-chain via **TEP-81 DNS**.

Creators choose one of two explicit guarantees. **Locked** transfers the parent `.ton` into the
collection and freezes resolution permanently. **Linked** keeps the parent in the owner's wallet,
supports trustless owner claims through a parent NFT round trip, and can explicitly convert one-way
to Locked. All contracts are **non-upgradeable** (`embed_code`).

> Written in **Tolk** with the **[Acton](https://github.com/ton-blockchain/acton)** toolchain.

## Architecture

Three tiers, each non-upgradeable:

| Tier | Contract | Role |
|------|----------|------|
| 0 | `SubdomainFactory` | One global, free, permissionless deployer. Derives collections and retains phase-aware recovery state until deployment and custody are positively acknowledged. |
| 1 | `SubdomainCollection` | One per domain. Custody, Linked claims, access policy, immutable pricing, mint and DNS routing. |
| 2 | `SubdomainItem` | One per subdomain. TEP-62 NFT holding DNS records, `dnsresolve`, transfer. |

## How it works

- **Create Locked (1 wallet tx).** The owner transfers their `.ton` to the factory carrying
  `{metadata + price preset}`. Internally, the factory records a pending deployment, the collection
  initializes and replies `CollectionReady`, and only then is the NFT handed into permanent custody.
  The pending record is cleared only after the collection persists the authenticated parent landing
  and replies `ParentHandoffComplete`. Rich bounces and lost callbacks remain phase-aware and retryable.
  The NFT transfer must attach about `0.75 TON` and forward at least `0.5 TON` to the factory; the
  shipped frontend pins `0.6 TON`. Do not reduce this forward amount: TON DNS permits dust
  notifications whose recipient compute phase is skipped before factory code can record recovery.
- **Create Linked (2 txs).** The creator asks the factory to deploy a creator-bound collection, then
  sets the parent `.ton`'s `next_resolver` from their wallet. The parent never leaves their custody.
  A buyer can later claim Collection control without the seller by temporarily transferring the
  parent through the Collection with a `0.01 TON` forward amount and explicit action. Bundle transfer
  moves the parent and Collection control atomically; after a normal sale the buyer must claim.
- **Policy.** Registries can be public, allowlist-only or admin-only. The allowlist only controls
  mint access.
- **Pricing.** The monotonic length grid is chosen at creation, immutable and may contain zero prices.
- **Mint.** Registration deploys the item NFT and finalizes only after authenticated `ItemReady`.
  Failed deploys release the label and refund recoverable value.
- **Resolve.** Root, then `.ton` collection, then parent item, then the frozen `next_resolver`, then our collection, then `sha256(label)`, then item, then records.
- **Metadata.** Off-chain; the contract stores only a base URI set at creation. `set_content` (admin) re-points metadata without touching the price grid.

## Contract specification

See [`SPECS.md`](SPECS.md) for the normative storage layouts, messages, getters, permissions,
economics, DNS behavior, recovery rules and invariants of all three contracts.

## Deployment (mainnet)

v3 is implemented on its release branch and has not been deployed. Previous mainnet addresses are
private test deployments and are not migration or compatibility targets:

| | Address |
|---|---|
| Private test factory (v2.0) | `EQApI7v_L89-tdFN4uVug4aCUcPtD42vfudQ7AhBFlLBWO3c` |
| Earlier test factory (v1.1 Locked) | `EQBpE2VuJEGMNSRak7cQCHelIsyZKyQFddIsyhmkV0vdHuJs` |

v2.0.0 was deployed on mainnet on 2026-07-10 in transaction
[`cfccc7b1…60745f`](https://tonscan.org/tx/cfccc7b1d8247c40e863f555cd805004974256ed1b295d6f5e2d02ebff60745f).

## Develop

```bash
acton build                                            # compile (lint clean)
acton test tests                                       # unit/integration suite (use this path; bare test also scans source-func/)
acton script scripts/deploy-factory.tolk               # local preparation: prints exact address + hashes
acton script scripts/verify-fork.tolk --fork-net mainnet     # compatibility check against live mainnet state
acton rpc info <addr> --net mainnet                    # inspect an address
```

Broadcasting uses the configured `prod-deployer` wallet. Copy the values printed by the local
preparation run, review them, then pin every one explicitly; the script refuses to broadcast on a
missing or mismatched value:

```bash
EXPECTED_DEPLOYER_ADDRESS='<printed wallet>' \
EXPECTED_FACTORY_ADDRESS='<printed factory>' \
EXPECTED_FACTORY_CODE_HASH='<printed 0x hash>' \
EXPECTED_COLLECTION_CODE_HASH='<printed 0x hash>' \
EXPECTED_ITEM_CODE_HASH='<printed 0x hash>' \
EXPECTED_INITIAL_STORAGE_HASH='<printed 0x hash>' \
CONFIRM_FACTORY_DEPLOY=true \
CONFIRM_MAINNET=true \
scripts/deploy-factory-mainnet.sh
```

Do not set the confirmation flags before comparing the mainnet-only target, VM `GLOBALID`, wallet,
factory address and all three embedded-code hashes with the reviewed release artifacts. The launcher
accepts no network argument and hardcodes `--net mainnet`; the Tolk script independently rejects any
non-mainnet declaration and requires `CONFIRM_MAINNET` on every broadcast. This avoids relying on
Acton 1.1's script VM `GLOBALID` to distinguish endpoints (its testnet broadcast context currently
still exposes `-239`). The script also refuses an already-active target address. Deployment remains
a separate, explicit operation; tests and dry-runs never broadcast.

If validation rejects an executable Locked create, a deployment fails, or a final custody callback is
interrupted, the pending admin can prepare and run the phase-aware recovery script. It prints and pins
the real network identity and every target before broadcast; its fixed 0.5 TON covers every recovery
phase (unused deploy-phase value is refunded):

```bash
RETRY_WALLET_NAME='<configured pending-admin wallet>' \
EXPECTED_RETRY_ADMIN_ADDRESS='<printed admin wallet>' \
RETRY_FACTORY_ADDRESS='<deployed factory>' \
RETRY_COLLECTION_ADDRESS='<deterministic collection>' \
RETRY_QUERY_ID='<operator query id>' \
CONFIRM_COLLECTION_RETRY=true \
CONFIRM_MAINNET=true \
scripts/retry-collection-mainnet.sh
```

The frontend dApp lives in a separate repository.

## License

MIT. See [LICENSE](LICENSE).
