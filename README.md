# TON Subdomains

Anyone who owns a `.ton` domain can open their own subdomain registry. Each subdomain is a tradeable **TEP-62 NFT** that resolves on-chain via **TEP-81 DNS**.

Trustless by design: when a registry is created, the parent `.ton` is locked into it and its `next_resolver` is frozen to the registry forever. The operator can never seize or redirect a subdomain, and the platform never holds your NFT. All contracts are **non-upgradeable** (`embed_code`).

> Written in **Tolk** with the **[Acton](https://github.com/ton-blockchain/acton)** toolchain.

## Architecture

Three tiers, each non-upgradeable:

| Tier | Contract | Role |
|------|----------|------|
| 0 | `SubdomainFactory` | One global, free, permissionless deployer. Derives and deploys one collection per parent domain. Holds no NFT or value. |
| 1 | `SubdomainCollection` | One per domain. Custody and lock of the parent NFT, mint, resolver routing (`sha256(label)` to item), transferable admin, parent-lease keep-alive. |
| 2 | `SubdomainItem` | One per subdomain. TEP-62 NFT holding DNS records, `dnsresolve`, transfer. |

## How it works

- **Create (1 tx).** The owner transfers their `.ton` to the factory carrying `{metadata + price preset}`. In a single transaction the factory deploys the collection **already locked** and forwards the `.ton` to it. Prices are fixed at creation and **immutable** thereafter (`get_price(charCount)` is cacheable).
- **Mint.** `register_subdomain(label)` deploys the item NFT (owner = minter). Each registry sets a minimum length (1-4) and a price per length (1-char .. 10-char, then 11+); short names are premium. Surplus refunded.
- **Resolve.** Root, then `.ton` collection, then parent item, then the frozen `next_resolver`, then our collection, then `sha256(label)`, then item, then records.
- **Metadata.** Off-chain; the contract stores only a base URI set at creation. `set_content` (admin) re-points metadata without touching the price grid.

## Interface

The **admin** of a collection is the parent's previous owner, set when the domain is locked.

Operations sent to a **Collection**:

| Opcode | Op | Sender | Action |
|---|---|---|---|
| `0x49278399` | `RegisterSubdomain` | anyone | mint a subdomain (pay `price + 0.10`, surplus refunded) |
| `0x97be5c56` | `ProxyEditParentRecord` | admin | edit one of the parent `.ton`'s records (never its resolver) |
| `0x5cfedae5` | `FillUpParent` | anyone | renew the parent `.ton` lease |
| `0xe0329a90` | `EnforceResolver` | anyone | (re-)pin `next_resolver` to the collection |
| `0x7969d64e` | `SetContent` | admin | update metadata URIs (prices stay fixed) |
| `0x1e4b7535` | `WithdrawFees` | admin | withdraw collected revenue |
| `0x2b8af82e` | `TransferAdmin` | admin | hand over the admin role |
| `0xccef6e14` | `SetLabelReserved` | admin | reserve or free a label |
| `0x2096dda6` | `RescueNft` | admin | rescue a mis-routed NFT (never the parent) |
| `0x693d3950` | `GetRoyaltyParams` | anyone | TEP-66 royalty query (replies `report_royalty_params`) |
| `0x6c0c4b17` | `LockCollection` | factory only | deploy already locked (internal, factory to collection) |

Operations sent to a subdomain **Item** (the NFT owner manages their own records):

| Opcode | Op | Sender | Action |
|---|---|---|---|
| `0x5fcc3d14` | `TransferOwnership` | owner | transfer the subdomain NFT (TEP-62) |
| `0x4eb1f0f9` | `ChangeDnsRecord` | owner | set or delete one DNS record (TEP-81) |
| `0x1a0b9d51` | `EditContent` | owner | replace the full DNS record set |
| `0x2fcb26a2` | `GetStaticData` | anyone | TEP-62 static-data query |

Creating a collection is a single `TransferOwnership` of the parent `.ton` to the factory (no custom opcode from the sender).

**Factory** getters:

| Getter | Type | Returns |
|---|---|---|
| `get_collection_address(parent)` | `address` | deterministic collection address for a parent domain |

**Collection** getters:

| Getter | Type | Returns |
|---|---|---|
| `get_price(charCount)` | `coins` | mint price for a label of that length |
| `get_min_chars()` | `int` | the registry's minimum subdomain length (1-4) |
| `is_locked()` | `bool` | whether the parent is locked in (registry active) |
| `get_admin()` | `address?` | current admin (null if not locked) |
| `get_parent_domain()` | `address` | the parent `.ton` address |
| `get_minted_count()` | `int` | subdomains minted so far |
| `get_last_parent_fill_up()` | `int` | unix time of the last parent heartbeat attempt |
| `get_nft_address_by_index(i)` | `address` | item address for a label hash |
| `get_nft_content(i, c)` | `cell` | TEP-64 individual content for an item |
| `get_collection_data()` | `(int, cell, address?)` | minted supply, collection content, admin |
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
| **SubdomainFactory** | `EQA_zkHJB1N8qO33uXoSoA6V7iO_B5TzxIFCntoHKFx5RUak` |

The factory is live and non-upgradeable, so do not redeploy.

## Develop

```bash
acton build                                            # compile (lint clean)
acton test tests                                       # 69 tests (use `acton test tests`, not `acton test` alone, which scans source-func/)
acton script scripts/deploy-factory.tolk --fork-net mainnet   # dry-run against live state
acton rpc info <addr> --net mainnet                    # inspect an address
```

Broadcasting uses the configured `prod-deployer` wallet via `--net mainnet`.

The frontend dApp lives in a separate repository.

## License

MIT. See [LICENSE](LICENSE).
