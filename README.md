# TON Subdomains

Anyone who owns a `.ton` domain can open their own subdomain registry. Each subdomain is a tradeable **TEP-62 NFT** that resolves on-chain via **TEP-81 DNS**.

Creators choose one of two explicit guarantees. **Locked** transfers the parent `.ton` into the
collection and freezes resolution permanently. **Linked** keeps the parent in the owner's wallet and
delegates with a revocable `next_resolver` record; it can later upgrade one-way to Locked. All
contracts are **non-upgradeable** (`embed_code`).

> Written in **Tolk** with the **[Acton](https://github.com/ton-blockchain/acton)** toolchain.

## Architecture

Three tiers, each non-upgradeable:

| Tier | Contract | Role |
|------|----------|------|
| 0 | `SubdomainFactory` | One global, free, permissionless deployer. Derives collections and retains phase-aware recovery state until deployment and custody are positively acknowledged. |
| 1 | `SubdomainCollection` | One per domain. Locked or Linked custody state, mint, resolver routing (`sha256(label)` to item), transferable admin, parent-lease keep-alive. |
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
  Transferring it into the collection later upgrades Linked to Locked irreversibly.
- Prices are fixed at creation and **immutable** thereafter (`get_price(charCount)` is cacheable).
- **Mint.** `register_subdomain(label)` deploys the item NFT (owner = minter). Each registry sets a minimum length (1-4) and a price per length (1-char .. 10-char, then 11+); short names are premium. Surplus refunded.
- **Resolve.** Root, then `.ton` collection, then parent item, then the frozen `next_resolver`, then our collection, then `sha256(label)`, then item, then records.
- **Metadata.** Off-chain; the contract stores only a base URI set at creation. `set_content` (admin) re-points metadata without touching the price grid.

## Interface

The **admin** of a collection is the creator initially and may be transferred. In Linked mode the
admin and parent owner are separate roles: only the parent owner can connect, disconnect, renew or
lock the parent.

Operations sent to a **Collection**:

| Opcode | Op | Sender | Action |
|---|---|---|---|
| `0x49278399` | `RegisterSubdomain` | anyone | mint a subdomain (pay `price + 0.10`, surplus refunded) |
| `0x97be5c56` | `ProxyEditParentRecord` | admin, Locked | edit one parent record (never its resolver) |
| `0x5cfedae5` | `FillUpParent` | anyone, Locked | caller-funded parent `.ton` renewal |
| `0xe0329a90` | `EnforceResolver` | anyone, Locked | caller-funded resolver re-pin |
| `0x7969d64e` | `SetContent` | admin | update metadata URIs (prices stay fixed) |
| `0x1e4b7535` | `WithdrawFees` | admin | withdraw collected revenue |
| `0x2b8af82e` | `TransferAdmin` | admin | hand over the admin role |
| `0xccef6e14` | `SetLabelReserved` | admin | reserve or free a label |
| `0x2096dda6` | `RescueNft` | admin | rescue a mis-routed NFT; parent rescue only while Linked |
| `0x693d3950` | `GetRoyaltyParams` | anyone | TEP-66 royalty query (replies `report_royalty_params`) |
| `0x6c0c4b17` | `LockCollection` | factory only | initialize the derived collection (internal deployment step) |

Operations sent to a subdomain **Item** (the NFT owner manages their own records):

| Opcode | Op | Sender | Action |
|---|---|---|---|
| `0x5fcc3d14` | `TransferOwnership` | owner | transfer the subdomain NFT (TEP-62) |
| `0x4eb1f0f9` | `ChangeDnsRecord` | owner | set or delete one DNS record (TEP-81) |
| `0x1a0b9d51` | `EditContent` | owner | replace the full DNS record set |
| `0x2fcb26a2` | `GetStaticData` | anyone | TEP-62 static-data query |

Factory create entry points:

| Opcode | Op | Sender | Action |
|---|---|---|---|
| `0x05138d91` | `OwnershipAssigned` | parent `.ton` | create a born-Locked collection after NFT transfer |
| `0x4c494e4b` | `CreateLinkedCollection` | creator | deploy a creator-bound Linked collection without custody |
| `0x52545259` | `RetryCollectionDeployment` | pending admin | replay a stored deployment after a lost deploy/callback |
| `0x52445931` | `CollectionReady` | derived collection only | authenticated internal deployment acknowledgement |
| `0x48444f4b` | `ParentHandoffComplete` | derived collection only | authenticated final Locked custody acknowledgement |

**Factory** getters:

| Getter | Type | Returns |
|---|---|---|
| `get_collection_address(parent)` | `address` | deterministic collection address for a parent domain |
| `get_linked_collection_address(parent, creator)` | `address` | deterministic creator-bound Linked address |
| `get_deployed_count()` | `int` | unique successfully acknowledged collection addresses |

**Collection** getters:

| Getter | Type | Returns |
|---|---|---|
| `get_price(charCount)` | `coins` | mint price for a label of that length |
| `get_min_chars()` | `int` | the registry's minimum subdomain length (1-4) |
| `is_locked()` | `bool` | whether the collection is initialized/active (true for both custody modes) |
| `get_admin()` | `address?` | current admin (null if not locked) |
| `get_parent_domain()` | `address` | the parent `.ton` address |
| `get_is_linked()` | `bool` | current custody mode; may only change `true → false` |
| `get_linked_admin()` | `address` | immutable creator witness used in Linked address derivation |
| `get_minted_count()` | `int` | successfully initialized subdomain items |
| `get_last_parent_fill_up()` | `int` | unix time of the last parent heartbeat attempt |
| `get_nft_address_by_index(i)` | `address` | item address for a label hash |
| `get_nft_content(i, c)` | `cell` | TEP-64 individual content for an item |
| `get_collection_data()` | `(int, cell, address?)` | TEP-62 `next_item_index = -1` (hash-addressed), collection content, admin |
| `royalty_params()` | `(int, int, address)` | TEP-66 royalty (0%, destination = admin) |
| `dnsresolve(sub, cat)` | `(int, cell?)` | resolved prefix bits + record (routes to the item) |

**Item** getters:

| Getter | Type | Returns |
|---|---|---|
| `get_nft_data()` | `(bool, uint256, address, address?, cell?)` | init flag, index, collection, owner, content |
| `get_domain()` | `slice` | the label bytes |
| `get_minted_at()` | `int` | unix mint time |
| `get_last_touch()` | `int` | unix time of the last update |
| `dnsresolve(sub, cat)` | `(int, cell?)` | resolved prefix bits + record |

## Deployment (mainnet)

| | Address |
|---|---|
| **Production factory (v2.0 Locked + Linked)** | `EQApI7v_L89-tdFN4uVug4aCUcPtD42vfudQ7AhBFlLBWO3c` |
| Legacy factory (v1.1 Locked) | `EQBpE2VuJEGMNSRak7cQCHelIsyZKyQFddIsyhmkV0vdHuJs` |

v2.0.0 was deployed on mainnet on 2026-07-10 in transaction
[`cfccc7b1…60745f`](https://tonscan.org/tx/cfccc7b1d8247c40e863f555cd805004974256ed1b295d6f5e2d02ebff60745f).
The registry migration was applied first, then the production frontend was atomically repointed via
`NEXT_PUBLIC_FACTORY_ADDRESS`.

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
