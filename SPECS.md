# TON Subdomains v2.0.0: Contract Specification

## 1. Scope and status

This document specifies the public behavior and invariants of the three non-upgradeable contracts in
the v2.0.0 release. The deployed BOCs are the execution source of truth; the Tolk structs define exact
binary layouts.

| Contract | Role | Production code hash |
|---|---|---|
| `SubdomainFactory` | Deterministic collection deployment and recovery | `BA7A27075D800E4748663D7FA4251EA4A4CF742CDA489617BA4EB156884BF40A` |
| `SubdomainCollection` | Registry, custody mode, minting and label routing | `A9933516AA373A1FC82E941C8AA244E4D111E77A71E6EE8935136A7B07A5D4F0` |
| `SubdomainItem` | Transferable subdomain NFT and DNS record store | `6AD38CEAC3FB5696DDC22F65041E2E5816E43C90CD1B30826EE68ED375D60F3F` |

Production factory: `EQApI7v_L89-tdFN4uVug4aCUcPtD42vfudQ7AhBFlLBWO3c` on TON mainnet.

The protocol implements TEP-62 NFTs, TEP-64 off-chain metadata, TEP-66 royalties and TEP-81 DNS.
All deployed addresses are immutable. A protocol upgrade requires a new factory.

## 2. Architecture and custody

The factory embeds the collection code; every collection embeds the item code.

1. A parent domain maps to one deterministic collection address per creation mode.
2. A collection maps each raw label to `index = sha256(label)` and a deterministic item address.
3. DNS resolution delegates from the parent to the collection, then from the collection to the item.
4. The item returns its final DNS record.

### Locked

- The owner transfers the parent NFT to the factory with the creation metadata.
- The factory deploys the collection, waits for an authenticated readiness callback, then transfers the
  parent into the collection.
- The collection stores the parent permanently and pins its `dns_next_resolver` to itself.
- The parent cannot be rescued or redirected; public repair may only re-pin the same collection.

### Linked

- The creator deploys a creator-bound collection without transferring the parent.
- The real parent owner activates resolution by setting the parent `dns_next_resolver` to the collection.
- The parent remains transferable and the delegation remains revocable.
- Sending the parent NFT into the collection performs the only mode transition: `Linked -> Locked`.
- Collection admin and parent owner are independent roles.

Locked and Linked use distinct StateInit data and cannot occupy each other's address. A Linked address
also commits the original creator; transferring admin does not change that address witness.

### Trust boundaries

- Linked deployment binds the creator but does not prove parent ownership; only the actual parent
  owner can activate delegation on the parent contract.
- Canonical `.ton` collection verification and Browse indexing are off-chain concerns.
- Metadata URIs are off-chain and admin-mutable; pricing and on-chain ownership are not.
- The contracts use no oracle, privileged factory operator or upgrade authority.

## 3. Persistent state

Fields are serialized in the order shown.

### Factory

```text
FactoryStorage {
  deployedCount: uint64
  pending: map<collection_hash, PendingDeployment>
  deployed: map<collection_hash, unit>
}

PendingDeployment {
  deploymentId: uint64
  parentDomain: address
  admin: address
  queryId: uint64
  handoffValue: coins
  isLinked: bool
  phase: uint2
  meta: ref<CollectionMeta>
}
```

Pending phases are `AWAITING_COLLECTION`, `AWAITING_HANDOFF` and `RETURNING_PARENT`.

### Collection

```text
CollectionSkeleton { master, parentDomain, isLinked, linkedAdmin }

CollectionStorage {
  master: address
  parentDomain: address
  admin: address
  origin: ref<{ linkedAdmin, isLinkedAtDeployment, lastFactoryHandoff? }>
  isLinked: bool
  lastParentFillUp: uint32
  meta: ref<{ priceConfig, collectionContent, itemContentBaseUri }>
  reserved: map<label_hash, unit>
  minted: map<label_hash, unit>
  mintedCount: uint32
}
```

The skeleton has no refs. Initialized storage has refs; `is_locked()` reports this initialization
state, not the custody mode. `get_is_linked()` reports the current custody mode.

### Item

```text
ItemStorageNotInitialized { index: uint256, collectionAddress: address }

ItemStorageInitialized {
  index: uint256
  collectionAddress: address
  ownerAddress: address
  records: ref<DnsRecords>
  label: ref<raw_label>
  mintedAt: uint32
  lastTouch: uint32
  validUntil: uint32
}
```

`validUntil = 0` means perpetual ownership. `DnsRecords` is a TEP-81 dictionary keyed by
`sha256(category_name)`.

## 4. Factory interface

The factory has no admin, upgrade path, protocol fee or withdrawal path. Excess value is refunded.

| Opcode | Message | Authorized sender | Effect |
|---|---|---|---|
| `0x05138d91` | `OwnershipAssigned(queryId, oldOwner?, payload)` | Parent NFT | Starts Locked creation using the previous owner as admin |
| `0x4c494e4b` | `CreateLinkedCollection(queryId, parent, admin, meta)` | `admin` itself | Starts creator-bound Linked creation |
| `0x52445931` | `CollectionReady(deploymentId, queryId, parent, admin, currentAdmin, isLinked, isNew)` | Exact derived collection | Advances or completes deployment |
| `0x48444f4b` | `ParentHandoffComplete(deploymentId, queryId, parent, intendedAdmin)` | Exact Locked collection | Finalizes acknowledged parent custody |
| `0x52545259` | `RetryCollectionDeployment(queryId, collection)` | Pending admin | Replays the persisted pending phase |

Getters:

- `get_collection_address(parentDomain) -> address`
- `get_linked_collection_address(parentDomain, admin) -> address`
- `get_deployed_count() -> int`

`deployedCount` counts unique acknowledged collection addresses. Duplicate or late callbacks are
idempotent and return their attached value.

## 5. Collection interface

| Opcode | Message | Authorized sender | Effect |
|---|---|---|---|
| `0x49278399` | `RegisterSubdomain(queryId, label, setWalletToMinter, initialRecords?)` | Anyone in basechain | Validates and mints one deterministic item |
| `0x7969d64e` | `SetContent(queryId, meta)` | Admin | Replaces metadata URIs; preserves pricing |
| `0x1e4b7535` | `WithdrawFees(queryId, amount)` | Admin | Withdraws revenue while retaining the operating floor; `0` means maximum |
| `0x2b8af82e` | `TransferAdmin(queryId, newAdmin)` | Admin | Transfers registry administration and revenue rights |
| `0x97be5c56` | `ProxyEditParentRecord(queryId, key, value)` | Admin, Locked only | Sets or deletes one parent record except the resolver |
| `0x5cfedae5` | `FillUpParent(queryId)` | Anyone, Locked only | Caller-funded parent renewal |
| `0xe0329a90` | `EnforceResolver(queryId)` | Anyone, Locked only | Caller-funded resolver repair |
| `0xccef6e14` | `SetLabelReserved(queryId, labelHash, reserved)` | Admin | Reserves or releases a label hash |
| `0x2096dda6` | `RescueNft(queryId, nftAddress, toAddress)` | Admin | Rescues a stray NFT; never the parent while Locked |
| `0x693d3950` | `GetRoyaltyParams(queryId)` | Anyone | Returns zero royalty, destination admin |
| `0x48445052` | `ConfirmParentHandoff(deploymentId, queryId, parent, intendedAdmin)` | Factory | Recovers a lost handoff acknowledgement |

Internal lifecycle messages:

- `LockCollection (0x6c0c4b17)` carries `deploymentId`, `queryId`, `parent`, `admin`, `isLinked`
  and `meta`; it initializes only from the factory committed in StateInit.
- `OwnershipAssigned (0x05138d91)` from the exact parent completes Locked custody or upgrades Linked.
- `SubdomainInit (0x2428aaa6)` carries `queryId`, `index`, `minter`, `label`,
  `setWalletToMinter` and optional initial records.
- `CollectionReady` and `ParentHandoffComplete` are authenticated deployment callbacks.

Getters:

- `get_collection_data() -> (nextItemIndex, content, ownerAddress)`; `nextItemIndex = -1`
- `royalty_params() -> (0, 1000, admin)`
- `get_nft_address_by_index(index) -> address`
- `get_nft_content(index, individualContent) -> cell`
- `get_price(charCount) -> coins`
- `get_min_chars() -> int`
- `get_admin() -> address?`
- `get_parent_domain() -> address`
- `get_linked_admin() -> address`
- `get_minted_count() -> int`
- `get_last_parent_fill_up() -> int`
- `is_locked() -> bool`
- `get_is_linked() -> bool`
- `dnsresolve(subdomain, category) -> (resolvedBits, record?)`

## 6. Item interface

Only the exact collection may initialize an item. After initialization, only the NFT owner may
transfer it or modify its DNS records.

| Opcode | Message | Authorized sender | Effect |
|---|---|---|---|
| `0x5fcc3d14` | `TransferOwnership(queryId, newOwner, responseDestination?, customPayload?, forwardAmount, forwardPayload)` | Owner | TEP-62 ownership transfer |
| `0x4eb1f0f9` | `ChangeDnsRecord(queryId, key, value)` | Owner | Sets or deletes one DNS record |
| `0x1a0b9d51` | `EditContent(queryId, newContent)` | Owner | Replaces the complete DNS dictionary |
| `0x2fcb26a2` | `GetStaticData(queryId)` | Anyone | Returns index and collection address |

Getters:

- `get_nft_data() -> (isInitialized, index, collectionAddress, ownerAddress?, content?)`
- `get_editor() -> address?`
- `get_domain() -> slice`
- `get_minted_at() -> int`
- `get_last_touch() -> int`
- `get_valid_until() -> int`
- `dnsresolve(subdomain, category) -> (resolvedBits, record?)`

Shared replies and handoff payloads:

| Opcode | Body | Purpose |
|---|---|---|
| `0xd53276db` | `Excesses(queryId)` | Standard value refund or silent top-up |
| `0x05138d91` | `OwnershipAssigned(queryId, oldOwner?, payload)` | TEP-62 forwarded ownership notification |
| `0x8b771735` | `ReportStaticData(queryId, itemIndex, collection)` | TEP-62 static-data reply |
| `0xa8cb00ad` | `ReportRoyaltyParams(queryId, numerator, denominator, destination)` | TEP-66 royalty reply |
| `0x9f3acb9c` | `AdminAssigned(queryId, prevAdmin)` | New collection-admin notification |
| `0x48414e44` | `FactoryHandoff(deploymentId, requestQueryId, intendedAdmin)` | Locked custody generation proof |

## 7. Minting, pricing and DNS

### Labels

- Length: registry minimum `1..4`, maximum `126` bytes.
- Alphabet: lowercase `a-z`, digits `0-9`, and an interior hyphen.
- Labels must be byte-aligned and contain no refs.
- `index = sha256(raw_label)`; duplicate indexes cannot mint twice.
- Reserved labels are admin-only; all other valid labels are public.
- Optional initial records are validated before the label is reserved.

### Pricing

`PriceConfig` contains `minChars`, prices for lengths `1..10`, and one price for `11+`. The grid is
immutable, non-increasing by length, and its cheapest tier must be at least `0.05 TON`.

Mint value must cover:

```text
selected price + 0.07 TON item deployment + 0.03 TON fee buffer
```

The price stays in the collection as revenue. The item receives `0.07 TON`; excess payment is
refunded. A rich bounce from a failed item deployment releases the label, decrements the count and
refunds the buyer. When `setWalletToMinter` is true, initialization adds a wallet record pointing to
the minter alongside any supplied initial records.

### Resolution

```text
parent DNS item
  -> dns_next_resolver: collection
  -> collection hashes the first label and returns the deterministic item
  -> item returns the requested record
```

Category keys are `sha256("dns_next_resolver")`, `sha256("wallet")`, `sha256("site")` and
`sha256("storage")`. Category names and TL-B record prefixes are distinct; a next-resolver value is
encoded by `DnsNextResolver` as `dns_next_resolver#ba93 resolver:MsgAddressInt`.

An item returns its complete dictionary for category `0`, one record for a specific category, and a
`dns_next_resolver` response when additional subdomain bytes remain.

## 8. Economic constants

| Constant | Value | Purpose |
|---|---:|---|
| `MIN_CREATE_VALUE` | `0.50 TON` | Minimum value received by the factory for Locked creation |
| `COLLECTION_DEPLOY_VALUE` | `0.25 TON` | Initial collection balance |
| `FACTORY_GAS_MARGIN` | `0.01 TON` | Factory execution margin |
| `FACTORY_READY_VALUE` | `0.01 TON` | Collection callback value |
| `RESOLVER_PIN_FUND` | `0.10 TON` | Locked handoff/resolver repair funding |
| `ITEM_DEPLOY_COST` | `0.07 TON` | Initial item balance |
| `MINT_FEE_BUFFER` | `0.03 TON` | Mint execution margin |
| `MIN_TONS_FOR_STORAGE` | `0.05 TON` | Item balance retained across transfers |
| `COLLECTION_MIN_BALANCE` | `0.05 TON` | Collection storage reserve |
| `FWD_FEE_RESERVE` | `0.02 TON` | Collection forwarding reserve |
| `MIN_NAME_PRICE` | `0.05 TON` | Lowest permitted price tier |
| `MAX_MIN_CHARS` | `4` | Highest configurable minimum label length |
| `MIN_PARENT_FILL` | `0.05 TON` | Minimum public parent top-up |
| `PARENT_HEARTBEAT_AMOUNT` | `0.01 TON` | Automatic Locked heartbeat amount |
| `PARENT_HEARTBEAT_INTERVAL` | `1 day` | Maximum automatic heartbeat frequency |
| `ONE_YEAR` | `31,622,400 seconds` | Reserved constant; no active v2 lease path |

Linked creation requires at least `COLLECTION_DEPLOY_VALUE + FACTORY_GAS_MARGIN = 0.26 TON`.
Phase-aware recovery requires `0.26 TON` for collection deployment or `0.50 TON` for custody/return.

`WithdrawFees(0)` withdraws the maximum available amount while keeping
`COLLECTION_MIN_BALANCE + FWD_FEE_RESERVE`. Linked collections never spend collection funds on the
parent because they do not own it.

## 9. Required invariants

1. Factory, collection and item code are non-upgradeable and embedded transitively.
2. Only the exact derived collection can authenticate factory deployment callbacks.
3. Only the factory committed in StateInit can initialize a collection skeleton.
4. Only the exact collection can initialize an item, and `sha256(label)` must equal its index.
5. A label is recorded before deployment and released only after an authenticated rich bounce.
6. Pricing and minimum label length never change after collection initialization.
7. Linked can become Locked; Locked can never become Linked.
8. A Locked parent cannot be rescued or have its resolver changed by admin proxy.
9. Re-auctioned or rejected parent NFTs are returned instead of being stranded.
10. Pending factory state remains recoverable until deployment, custody or return is acknowledged.
11. Admin transfers do not change deterministic addresses or the immutable Linked creator witness.
12. Active contracts reject unknown non-empty opcodes with `0xFFFF`; a collection skeleton ignores
    everything except factory initialization. Empty top-ups and `Excesses` are accepted silently.

## 10. Error codes

| Code | Meaning | Code | Meaning |
|---:|---|---:|---|
| `70` | Invalid DNS query shape | `200` | Label too short |
| `201` | Label too long | `202` | Invalid label characters |
| `203` | Reserved label | `204` | Insufficient mint value |
| `207` | Label already minted | `211` | Wrong workchain |
| `212` | Locked parent rescue forbidden | `213` | Missing previous owner |
| `214` | Custody operation in Linked mode | `220` | Item index mismatch |
| `401` | Not owner | `402` | Insufficient balance |
| `403` | Not admin | `404` | Invalid collection sender |
| `405` | Invalid factory sender | `406` | Resolver edit forbidden |
| `412` | Invalid DNS content tag | `65535` | Unknown opcode |

## 11. Release gates

The v2.0.0 release must reproduce the three hashes in section 1 and pass:

```sh
acton build
acton test tests
acton check
acton fmt --check
```

Mainnet deployment scripts additionally pin the deployer, network, factory address, all three code
hashes and the initial storage hash before broadcasting.
