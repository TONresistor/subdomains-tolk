// Persistent storage + state loaders + deterministic address derivation.
import "dns-utils"
import "errors"
import "prices"

// ---- fee/economy constants ----
const MIN_TONS_FOR_STORAGE = ton("0.05")
const ITEM_DEPLOY_COST = ton("0.07")
const MINT_FEE_BUFFER = ton("0.03")
const COLLECTION_MIN_BALANCE = ton("0.05")
const LEASE_RESERVE = ton("0.3")
const COLLECTION_DEPLOY_VALUE = ton("0.25")
const FACTORY_GAS_MARGIN = ton("0.01")
const RESOLVER_PIN_FUND = ton("0.1")
const MIN_CREATE_VALUE = ton("0.5")
const PARENT_FILL_AMOUNT = ton("0.2")
const FWD_FEE_RESERVE = ton("0.02")
const ONE_YEAR = 31622400
const PARENT_HEARTBEAT_INTERVAL = 86400 // 1 day
const PARENT_HEARTBEAT_AMOUNT = ton("0.01")
const PER_NAME_RENT_RESERVE = ton("0.003")

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
}

struct CollectionMeta {
    priceConfig: Cell<PriceConfig>
    collectionContent: cell  // TEP-64 offchain (collection)
    itemContentBaseUri: cell // offchain prefix for items
}

struct CollectionStorage {
    master: address
    parentDomain: address
    admin: address
    lastParentFillUp: uint32
    meta: Cell<CollectionMeta>
    reserved: map<uint256, ()>
    minted: map<uint256, ()>
    mintedCount: uint32
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
    mintedAt: uint32
    lastTouch: uint32
    validUntil: uint32 // 0 = perpetual (reserved)
}

fun ItemStorageInitialized.save(self) {
    contract.setData(self.toCell());
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
    collectionCode: cell,
): AutoDeployAddress {
    val skeleton: CollectionSkeleton = { master, parentDomain };
    return { workchain: BASECHAIN, stateInit: { code: collectionCode, data: skeleton.toCell() } };
}
