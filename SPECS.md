# TON Subdomains v5.0.0

## Scope

The protocol deploys non-upgradeable subdomain registries from Factory
`EQADqpHyfQRvWQGxPqJt6Jyu_c2oqxFZgvfdfxb4UZkCE8R9`.

It implements TEP-62 NFTs, TEP-64 metadata, TEP-66 royalties and TEP-81 DNS. Contracts accept any compatible parent NFT. Project clients support `.ton` domains and wallet-owned `.t.me` Telegram Username NFTs that are not in an active auction.

## Architecture

Factory embeds Collection code; Collection embeds Item code. Addresses are derived from StateInit.
Locked Collections are keyed by parent; Linked Collections by parent and original creator.

Message layouts: [messages.tolk](contracts/messages.tolk). Storage: [storage.tolk](contracts/storage.tolk).

## Collection modes

| | Locked | Linked |
|---|---|---|
| Parent custody | Held permanently by Collection | Kept in its owner's wallet |
| Resolver | Collection pins itself as `dns_next_resolver` | Parent owner sets `dns_next_resolver` |
| Admin changes | Current admin may transfer the role | Proven parent owner must claim |
| Revenue | Current admin may withdraw | Proven parent owner claims and withdraws |
| Conversion | Final | One-way conversion to Locked |

### Locked

The parent is transferred through Factory to Collection and can never be rescued. Collection may proxy parent DNS edits, except changes to `dns_next_resolver`.

`autoRenewParent` is immutable. When enabled, a due mint sends `0.01 TON` to the parent at most once per 24 hours. Project clients enable it for `.ton` and disable it for non-expiring `.t.me` parents.
There is no autonomous keeper in the contracts: anyone may also fund `FillUpParent`.

### Linked

A Linked Collection address is bound to the parent and its original creator. A later parent owner
can take control without permission from the previous admin:

1. Transfer the parent NFT to Collection with a Linked action. Project clients forward at least
   `0.01 TON`.
2. Collection accepts proof only from the exact parent address.
3. Collection applies the action and returns the parent when required.

| Action | Value | Result |
|---|---:|---|
| `CLAIM` | `1` | Parent owner becomes admin, receives available revenue, and gets the parent back |
| `CONVERT_LOCKED` | `3` | Parent owner becomes admin and Collection keeps the parent permanently |

Missing, malformed or unknown actions only return the parent. Direct admin transfer and withdrawal are disabled while Linked. A zero forward amount cannot produce the ownership callback and is not recoverable by Collection.

If an authenticated return lacks funds, `RetryParentReturn` lets any caller fund it. The recipient
cannot change, and only one return can be in flight.

## Configuration

### Access

| Value | Mode | Who may mint |
|---:|---|---|
| `0` | Public | Anyone |
| `1` | Allowlist | Admin and allowlisted wallets |
| `2` | Admin only | Admin |

The admin can change access mode, allowlist entries and reserved labels. Reserved labels remain mintable by the admin. Access rules never change price.

### Labels and pricing

- Labels contain 1 to 126 ASCII bytes: `a-z`, `0-9`, and interior `-`.
- `minChars` may be 1 to 4.
- Immutable prices cover lengths `1` through `10`, plus one price for `11+`.
- Prices must not increase as labels get longer. Zero is valid.
- Item index and address use `sha256(raw_label)`.

`get_mint_quote(wallet, charCount)` returns whether the wallet may mint, the price, and the required attached value.

### Metadata

Collection and Item metadata is immutable TEP-64 on-chain content with tag `0`, limited to 32 cells
and 16,384 bits per content tree. Clients choose the fields and URI schemes; contracts validate
the container structure and size.

## Minting and revenue

1. Collection validates the sender, label, metadata, access, price and attached value.
2. It reserves the label and deploys the deterministic Item.
3. The exact Item confirms initialization with `ItemReady`.
4. Collection marks the label minted and credits only its price as revenue.

An Item starts with immutable metadata and editable TEP-81 DNS records. `setWalletToMinter` may add the minter's wallet record during creation. The Item owner can transfer the NFT, replace all DNS records, or change one record.

A failed Item deployment releases the label and refunds recoverable value. If confirmation is lost,
any caller may fund `ConfirmMint`; Collection verifies the exact Item and its Collection before
finalizing.

Withdrawals cannot exceed accounted revenue or the balance available above operational reserves.

Top-ups and execution funding do not become revenue. Royalties are zero.

Factory and Collection recovery messages are caller-funded and authenticate the sender and pending operation.

## Get methods

Generated typed wrappers are committed in [`wrappers/`](wrappers/).

- **Factory:** `get_collection_address`, `get_linked_collection_address`.
- **Collection standards:** `get_collection_data`, `get_nft_address_by_index`,
  `get_nft_content`, `royalty_params`, `dnsresolve`.
- **Collection state:** `get_parent_domain`, `get_admin`, `get_linked_admin`, `get_is_linked`,
  `is_locked`, `get_min_chars`, `get_price`, `get_access_mode`, `get_is_allowlisted`,
  `get_mint_quote`, `get_minted_count`, `get_is_mint_pending`, `get_withdrawable_revenue`,
  `get_auto_renew_parent`, `get_last_parent_fill_up`, `get_parent_return`.
- **Item:** `get_nft_data`, `get_editor`, `get_domain`, `get_minted_at`, `get_last_touch`,
  `get_valid_until`, `dnsresolve`.

Exact return structs are defined in [`contracts/storage.tolk`](contracts/storage.tolk). Canonical
exit codes are defined in [`contracts/errors.tolk`](contracts/errors.tolk).

## ABI opcodes

### TON standards

| Opcode | Message | Use |
|---|---|---|
| `0x5fcc3d14` | `TransferOwnership` | TEP-62 NFT transfer |
| `0x05138d91` | `OwnershipAssigned` | TEP-62 transfer notification and parent proof |
| `0xd53276db` | `Excesses` | TEP-62 acknowledgement or refund |
| `0x2fcb26a2` | `GetStaticData` | Request Item identity |
| `0x8b771735` | `ReportStaticData` | Return Item identity |
| `0x693d3950` | `GetRoyaltyParams` | Request TEP-66 royalty data |
| `0xa8cb00ad` | `ReportRoyaltyParams` | Return zero royalty data |
| `0x4eb1f0f9` | `ChangeDnsRecord` | Change one TEP-81 DNS record |
| `0x1a0b9d51` | `EditContent` | Replace all TEP-81 DNS records |

`0xba93` is the `dns_next_resolver` record tag, not a message opcode.

### Protocol

| Opcode | Message or payload | Use |
|---|---|---|
| `0x6c0c4b17` | `LockCollection` | Initialize Collection from Factory |
| `0x52445931` | `CollectionReady` | Confirm Collection deployment to Factory |
| `0x48444f4b` | `ParentHandoffComplete` | Confirm Locked parent custody to Factory |
| `0x48445052` | `ConfirmParentHandoff` | Probe a pending Locked handoff |
| `0x52545259` | `RetryCollectionDeployment` | Retry a Factory deployment phase |
| `0x4c494e4b` | `CreateLinkedCollection` | Create a Linked Collection |
| `0x48414e44` | `FactoryHandoff` | Authenticate the Locked parent handoff payload |
| `0x2428aaa6` | `SubdomainInit` | Initialize an Item from Collection |
| `0x49524459` | `ItemReady` | Confirm Item deployment to Collection |
| `0x49278399` | `RegisterSubdomain` | Mint a subdomain Item |
| `0x1e4b7535` | `WithdrawFees` | Withdraw Locked Collection revenue |
| `0x2b8af82e` | `TransferAdmin` | Transfer Locked Collection admin |
| `0x9f3acb9c` | `AdminAssigned` | Notify the new admin |
| `0x97be5c56` | `ProxyEditParentRecord` | Edit a Locked parent DNS record |
| `0x5cfedae5` | `FillUpParent` | Fund parent renewal |
| `0xe0329a90` | `EnforceResolver` | Restore the Locked parent resolver |
| `0xccef6e14` | `SetLabelReserved` | Reserve or release a label hash |
| `0x2096dda6` | `RescueNft` | Rescue an unrelated NFT |
| `0x41434353` | `SetAccessMode` | Change mint access mode |
| `0x414c4c57` | `SetAllowlistEntry` | Add or remove an allowlist entry |
| `0x52505254` | `RetryParentReturn` | Retry a Linked parent return |
| `0x434d494e` | `ConfirmMint` | Recover a pending mint confirmation |
| `0x4c4e4b33` | `LinkedParentAction` | Carry `CLAIM` or `CONVERT_LOCKED` in a parent transfer |

## Transaction values

These values fund execution; they are not protocol fees. Supported excess amounts are returned when
the message flow permits it. Other messages still need enough value for normal execution.

| Operation | Required value |
|---|---:|
| Create Linked | `0.135 TON` |
| Create Locked | Parent transfer forwards at least `0.20 TON` |
| Mint | Price plus `0.07 TON` |
| Mint with due parent renewal | Price plus `0.08 TON` |
| Linked parent action | Project client forwards at least `0.01 TON` |
| Retry Linked parent return | `0.01 TON` |
| Fill parent | `0.01 TON` |
| Enforce resolver | `0.02 TON` |
| Confirm pending mint | `0.005 TON` |
| Replay Factory Collection deployment phase | `0.135 TON` |
| Retry Factory handoff or return phase | `0.10 TON` |

The extra `0.01 TON` renewal applies only to Locked Collections with `autoRenewParent` enabled and a
heartbeat due.
