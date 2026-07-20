// Persistent storage + state loaders + deterministic address derivation.
import "dns-utils"
import "errors"
import "prices"

// ---- fee/economy constants ----
const MIN_TONS_FOR_STORAGE = ton("0.05")
const ITEM_DEPLOY_COST = ton("0.06")
const ITEM_READY_VALUE = ton("0.002")
const MINT_FEE_BUFFER = ton("0.01")
const COLLECTION_MIN_BALANCE = ton("0.05")
const COLLECTION_DEPLOY_VALUE = ton("0.13")
const FACTORY_READY_VALUE = ton("0.002")
const FACTORY_GAS_MARGIN = ton("0.005")
const RESOLVER_PIN_VALUE = ton("0.01")
const RESOLVER_PIN_FUND = ton("0.02")
const MIN_CREATE_VALUE = ton("0.2")
const MIN_PARENT_FILL = ton("0.01") // min incoming value for a caller-funded parent renew
const FWD_FEE_RESERVE = ton("0.02")
const PARENT_HEARTBEAT_INTERVAL = 86400 // 1 day
const PARENT_HEARTBEAT_AMOUNT = ton("0.01")
const MIN_PARENT_RETURN_VALUE = ton("0.01")
const MIN_CONFIRM_MINT_VALUE = ton("0.005")
const HANDOFF_RETRY_VALUE = ton("0.1")
const HANDOFF_CONFIRM_VALUE = ton("0.02")
const MIN_REJECTED_RETURN_VALUE = ton("0.05")
// ---- access/pricing constants ----
const ACCESS_PUBLIC: uint8 = 0
const ACCESS_ALLOWLIST: uint8 = 1
const ACCESS_ADMIN_ONLY: uint8 = 2

const LINKED_ACTION_CLAIM: uint8 = 1
const LINKED_ACTION_CONVERT_LOCKED: uint8 = 3

// ---- DNS records (TEP-81) ----
type DnsRecords = map<uint256, cell>

fun DnsRecords.packToBuilder(self, mutate b: builder) {
    b.storeUint(0, BYTE_SIZE);
    b.storeDict(self.toLowLevelDict());
}

fun DnsRecords.unpackFromSlice(mutate s: slice): DnsRecords {
    assert (s.loadUint(BYTE_SIZE) == 0) throw ERROR_CONTENT_TAG_INVALID;
    return createMapFromLowLevelDict<uint256, cell>(s.loadDict());
}

struct DnsResolveResponse {
    resolvedPrefixLengthBits: int
    resolvedRecord: cell?
}

// =========================== COLLECTION (Tier 1) ===========================

struct CollectionSkeleton {
    master: address
    parentDomain: address
    // Part of StateInit: Linked and Locked cannot pre-occupy each other's address.
    isLinked: bool
    // Creator binding prevents third-party pre-deployment of a Linked collection.
    linkedAdmin: address
}

struct CollectionMeta {
    priceConfig: Cell<PriceConfig>
    autoRenewParent: bool
    collectionContent: cell // immutable TEP-64 on-chain collection metadata
}

struct CollectionOrigin {
    linkedAdmin: address
    isLinkedAtDeployment: bool
    lastFactoryHandoff: Cell<FactoryHandoffReceipt>?
}

// Receipt used to recover a lost factory handoff callback.
struct FactoryHandoffReceipt {
    deploymentId: uint64
    requestQueryId: uint64
    intendedAdmin: address
    returnRequired: bool
    returnInFlight: bool = false
}

struct PendingMint {
    queryId: uint64
    minter: address
    price: coins
}

struct PendingParentReturn {
    returnQueryId: uint64
    requestQueryId: uint64
    recipient: address
    inFlight: bool = false
}

struct CollectionPolicyState {
    accessMode: uint8
    withdrawableRevenue: coins
    allowlist: map<address, ()>
    pendingMints: map<uint256, Cell<PendingMint>>
    parentGeneration: uint64
    pendingParentReturn: Cell<PendingParentReturn>?
}

struct CollectionNames {
    reserved: map<uint256, ()>
    minted: map<uint256, ()>
    mintedCount: uint32
}

struct CollectionStorage {
    master: address
    parentDomain: address
    admin: address
    // Immutable address witness plus the latest handoff receipt.
    origin: Cell<CollectionOrigin>
    // true = Linked; false = terminal Locked custody.
    isLinked: bool
    lastParentFillUp: uint32
    meta: Cell<CollectionMeta>
    names: Cell<CollectionNames>
    policy: Cell<CollectionPolicyState>
}

fun CollectionStorage.save(self) {
    contract.setData(self.toCell());
}

struct CollectionLoader {
    cs: slice
}

fun startLoadingCollection(): CollectionLoader {
    return { cs: contract.getData().beginParse() };
}

fun CollectionLoader.isLocked(self): bool {
    return self.cs.remainingRefsCount() > 0;
}

fun CollectionLoader.parseSkeleton(self): CollectionSkeleton {
    return CollectionSkeleton.fromSlice(self.cs);
}

fun CollectionLoader.parseLocked(self): CollectionStorage {
    return CollectionStorage.fromSlice(self.cs);
}

struct CollectionDataReply {
    nextItemIndex: int
    content: cell
    ownerAddress: address?
}

struct MintQuoteReply {
    allowed: bool
    effectivePrice: coins
    requiredValue: coins
}

struct ParentReturnReply {
    pending: bool
    returnQueryId: uint64
    requestQueryId: uint64
    recipient: address?
    inFlight: bool = false
}

// =========================== ITEM (Tier 2) ===========================

struct ItemStorageNotInitialized {
    index: uint256
    collectionAddress: address
}

struct ItemStorageInitialized {
    index: uint256
    collectionAddress: address
    ownerAddress: address
    records: Cell<DnsRecords>
    label: Cell<RemainingBitsAndRefs>
    content: cell      // immutable complete TEP-64 on-chain item metadata
    mintedAt: uint32
    lastTouch: uint32
    validUntil: uint32 // 0 = perpetual (reserved)
}

struct ItemLoader {
    cs: slice
}

fun startLoadingItemStorage(): ItemLoader {
    return { cs: contract.getData().beginParse() };
}

fun ItemLoader.isInitialized(self): bool {
    return self.cs.remainingRefsCount() > 0;
}

fun ItemLoader.parseNotInitialized(self): ItemStorageNotInitialized {
    return ItemStorageNotInitialized.fromSlice(self.cs);
}

fun ItemLoader.parseInitialized(self): ItemStorageInitialized {
    return ItemStorageInitialized.fromSlice(self.cs);
}

struct ItemNftDataReply {
    isInitialized: bool
    index: uint256
    collectionAddress: address
    ownerAddress: address?
    content: cell?
}

// =========================== deterministic derivation ===========================

fun calcDeployedItem(index: uint256, itemCode: cell): AutoDeployAddress {
    val skeleton: ItemStorageNotInitialized = { index, collectionAddress: contract.getAddress() };
    return { workchain: BASECHAIN, stateInit: { code: itemCode, data: skeleton.toCell() } };
}

fun calcDeployedCollection(
    master: address,
    parentDomain: address,
    isLinked: bool,
    linkedAdmin: address,
    collectionCode: cell,
): AutoDeployAddress {
    val skeleton: CollectionSkeleton = {
        master,
        parentDomain,
        isLinked,
        linkedAdmin,
    };
    return { workchain: BASECHAIN, stateInit: { code: collectionCode, data: skeleton.toCell() } };
}
