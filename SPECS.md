# TON Subdomains v4.0.0 Specification

## 1. Status

This document defines the three non-upgradeable v4 contracts deployed from Factory
`EQAAzQese032pNIO5T-eOxb5bDjdGJ1m0-iutqd86ZH39nXN`.

Previous mainnet deployments are private tests and are not compatibility targets. The v4 release
deploys new addresses without an on-chain migration path.

The protocol implements TEP-62 NFTs, TEP-64 metadata, TEP-66 royalties and TEP-81 DNS.

## 2. Architecture

```text
SubdomainFactory
  -> SubdomainCollection per parent .ton
       -> SubdomainItem per sha256(raw_label)
```

- Factory embeds Collection code.
- Collection embeds Item code.
- StateInit determines every address.
- No contract has an upgrade authority.
- Factory has no admin, protocol fee or withdrawal path.

## 3. Custody modes

### Locked

The parent NFT is transferred through Factory into Collection custody. Collection permanently owns
the parent, pins itself as `dns_next_resolver`, renews the parent and forbids parent rescue.

### Linked

The parent remains in its owner's wallet. The owner sets the parent `dns_next_resolver` to the
Collection. Linked ownership is synchronized through an authenticated parent round trip:

1. Current parent owner transfers the parent to Collection with a positive forward amount and action.
   Official clients use at least `MIN_PARENT_RETURN_VALUE` (`0.01 TON`).
2. The canonical parent sends `OwnershipAssigned` with the previous owner and action.
3. Collection verifies the exact parent sender and action.
4. Collection updates state and persists the fixed return recipient. At `0.01 TON` or more it sends
   the return immediately; otherwise any caller can fund the retry.
5. Authenticated `Excesses` from the parent clears the pending return and forwards remaining value.

The original `linkedAdmin` remains an immutable StateInit witness. `admin` is the last controller
authenticated by a parent proof, not an automatic mirror of an unrelated parent sale. After a normal
sale, the buyer claims unilaterally.

`LinkedParentAction (0x4c4e4b33)` actions:

| Value | Action | Result |
|---:|---|---|
| `1` | Claim | Previous parent owner becomes admin, receives available revenue, parent returned |
| `3` | Convert Locked | Previous parent owner becomes admin, Collection retains parent permanently |

Missing, malformed or unknown actions never convert custody. They trigger safe return. Direct
`TransferAdmin` and `WithdrawFees` are disabled in Linked mode. `Claim` requires a fresh parent proof
and withdraws the maximum accounted revenue allowed by the physical balance and operational reserve.

`RetryParentReturn` is permissionless, caller-funded and cannot change the stored recipient. Only one
parent transfer may be in flight; an authenticated RichBounce unlocks another attempt.

`RescueNft` never accepts the parent in either mode. A zero forward amount emits no ownership proof
and is unrecoverable on-chain. A positive but underfunded notification can persist a receipt for
caller-funded retry. The initial callback deliberately does not reject low value after custody has
already moved; clients enforce `MIN_PARENT_RETURN_VALUE`.

## 4. Access policy

Every Collection has one mode:

| Value | Mode | Allowed minters |
|---:|---|---|
| `0` | Public | Any basechain address |
| `1` | Allowlist | Admin plus allowlisted wallets |
| `2` | Admin only | Admin only |

The allowlist is a simple address set. It never changes pricing.

## 5. Pricing and quotes

`PriceConfig` contains `minChars`, prices for lengths `1..10`, and one price for `11+`. It is chosen
at Collection creation and immutable afterwards. Prices must be non-increasing by label length. Zero
is valid, including a fully free grid.

`get_mint_quote` reports live authorization, immutable price and required execution value.

Base required mint value is:

```text
effectivePrice + ITEM_DEPLOY_COST + MINT_FEE_BUFFER
```

A free mint requires `0.07 TON`. A Locked mint adds `0.01 TON` only when its once-per-day parent
heartbeat is due. `get_mint_quote` includes that heartbeat when due. These amounts fund execution
and Item creation, not protocol revenue.

## 6. Mint lifecycle and accounting

1. Collection validates label, policy, price and funding.
2. Collection reserves `PendingMint`.
3. Collection deploys the deterministic Item with a rich bounce.
4. Item persists its state and sends authenticated `ItemReady`.
5. Collection finalizes the label, increments `mintedCount` and credits only the effective price to
   `withdrawableRevenue`.

On deployment bounce, Collection removes the pending label and refunds recoverable value. If the
`ItemReady` transaction fails, any caller can fund `ConfirmMint`; Collection asks the exact Item for
`ReportStaticData` and finalizes only after authenticating its address and collection field.

Withdrawals are limited by both `withdrawableRevenue` and the physical balance above operational
reserves. Top-ups, parent return surplus and execution funding are not automatically revenue.

## 7. Storage

```text
FactoryStorage {
  pending, rejectedReturns
}

PendingDeployment {
  deploymentId, parentDomain, admin, queryId,
  handoffValue, isLinked, phase, meta, inFlight
}

FactoryPendingReturn {
  deploymentId, parentDomain, admin, queryId, inFlight
}

CollectionSkeleton {
  master, parentDomain, isLinked, linkedAdmin
}

CollectionStorage {
  master, parentDomain, admin, origin, isLinked,
  lastParentFillUp, meta, names, policy
}

CollectionNames {
  reserved, minted, mintedCount
}

CollectionPolicyState {
  accessMode, withdrawableRevenue, allowlist,
  pendingMints, parentGeneration, pendingParentReturn?
}
```

Rejected returns never retain caller-supplied metadata.

Item storage remains TEP-62 compatible and contains index, Collection, owner, records, raw label and
timestamps.

## 8. Contract interfaces

Factory messages:

| Message | Purpose |
|---|---|
| `OwnershipAssigned` | Start Locked creation from authenticated parent custody |
| `CreateLinkedCollection` | Deploy a creator-bound Linked Collection |
| `CollectionReady`, `ParentHandoffComplete` | Advance authenticated deployment phases |
| `RetryCollectionDeployment` | Probe an active handoff or replay a bounced phase with caller funding |

Factory getters are `get_collection_address` and `get_linked_collection_address`.

Collection messages:

| Opcode | Message | Authority |
|---|---|---|
| `0x49278399` | `RegisterSubdomain` | Policy-authorized minter |
| `0x49524459` | `ItemReady` | Exact derived Item |
| `0x41434353` | `SetAccessMode` | Admin |
| `0x414c4c57` | `SetAllowlistEntry` | Admin |
| `0x7969d64e` | `SetContent` | Admin, pricing preserved |
| `0xccef6e14` | `SetLabelReserved` | Admin |
| `0x1e4b7535` | `WithdrawFees` | Locked admin only |
| `0x2b8af82e` | `TransferAdmin` | Locked admin only |
| `0x97be5c56` | `ProxyEditParentRecord` | Locked admin only |
| `0x5cfedae5`, `0xe0329a90` | `FillUpParent`, `EnforceResolver` | Anyone, caller-funded, Locked only |
| `0x2096dda6` | `RescueNft` | Admin, parent always forbidden |
| `0x693d3950` | `GetRoyaltyParams` | Anyone |
| `0x48445052` | `ConfirmParentHandoff` | Factory |
| `0x52505254` | `RetryParentReturn` | Anyone, caller-funded |
| `0x434d494e` | `ConfirmMint` | Anyone, caller-funded |

Collection getters cover TEP-62 and TEP-66 data, DNS resolution, addresses, custody mode, immutable
pricing, access policy, mint state, revenue and pending parent return.

Item messages are standard TEP-62 `TransferOwnership` and `GetStaticData`, plus TEP-81
`ChangeDnsRecord` and `EditContent`. Item getters expose NFT data, editor, raw label, timestamps and
`dnsresolve`. TEP-62 ownership, static-data and excess layouts are unchanged.

## 9. Economic constants

| Constant | Value |
|---|---:|
| `MIN_CREATE_VALUE` | `0.20 TON` |
| `COLLECTION_DEPLOY_VALUE` | `0.13 TON` |
| `FACTORY_GAS_MARGIN` | `0.005 TON` |
| `FACTORY_READY_VALUE` | `0.002 TON` |
| `ITEM_DEPLOY_COST` | `0.06 TON` |
| `ITEM_READY_VALUE` | `0.002 TON` |
| `MINT_FEE_BUFFER` | `0.01 TON` |
| `COLLECTION_MIN_BALANCE` | `0.05 TON` |
| `FWD_FEE_RESERVE` | `0.02 TON` |
| `RESOLVER_PIN_VALUE` | `0.01 TON` |
| `RESOLVER_PIN_FUND` | `0.02 TON` |
| `MIN_PARENT_FILL` | `0.01 TON` |
| `PARENT_HEARTBEAT_AMOUNT` | `0.01 TON`, at most once per 24 hours through mint |
| `MIN_PARENT_RETURN_VALUE` | `0.01 TON` |
| `MIN_CONFIRM_MINT_VALUE` | `0.005 TON` |
| `HANDOFF_RETRY_VALUE` | `0.10 TON` |
| `HANDOFF_CONFIRM_VALUE` | `0.02 TON` |
| `MIN_REJECTED_RETURN_VALUE` | `0.05 TON` |

An exact Linked creation costs `0.135 TON`. An exact Locked parent notification forwards `0.20 TON`
to Factory. Recovery sends at most `0.135 TON`; unused value is refunded where the phase allows it.

## 10. Release invariants

1. Only the canonical parent can prove Linked ownership.
2. A malformed parent payload cannot cause Locked conversion.
3. A pending parent return cannot change recipient during retry.
4. Linked revenue is withdrawn only by a fresh parent claim.
5. A label is in at most one state: pending or minted.
6. Failed Item deployment restores the label and refunds recoverable value.
7. Only finalized mint price becomes withdrawable revenue.
8. Factory and deterministic address witnesses remain immutable.
9. A cached Linked admin can never rescue the parent without a fresh ownership proof.
10. Linked clients must use at least `MIN_PARENT_RETURN_VALUE` as the parent forward amount.
11. Rejected Factory custody stores only a bounded return receipt, never untrusted metadata.
12. Factory and Collection never emit a second parent transfer before success or authenticated bounce.
13. Collection counts are indexed from authenticated deployment events, not duplicated in Factory
    storage.
14. Mainnet release requires reproducible BOCs, TON Verifier publication, full tests, coverage and
    mutation gates, pinned deployment values and atomic indexer/frontend cutover.
