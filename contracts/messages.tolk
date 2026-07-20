// Message bodies (opcode structs). Opcodes are crc32 (custom) or TEP-62 (reused).
import "storage"

type TransferForwardPayload = RemainingBitsAndRefs

// ---------------- TEP-62 (reused) ----------------
struct TransferOwnershipData {
    newOwnerAddress: address
    responseDestination: address?
    customPayload: cell?
    forwardAmount: coins
    forwardPayload: TransferForwardPayload
}

struct (0x5fcc3d14) TransferOwnership {
    queryId: uint64
    transferData: TransferOwnershipData
}

struct (0x05138d91) OwnershipAssigned {
    queryId: uint64
    oldOwnerAddress: address?
    payload: TransferForwardPayload
}

struct (0xd53276db) Excesses {
    queryId: uint64
}

struct (0x2fcb26a2) GetStaticData {
    queryId: uint64
}

struct (0x8b771735) ReportStaticData {
    queryId: uint64
    itemIndex: uint256
    collectionAddress: address
}

// ---------------- TEP-66 royalties ----------------
struct (0x693d3950) GetRoyaltyParams {
    queryId: uint64
}

struct (0xa8cb00ad) ReportRoyaltyParams {
    queryId: uint64
    numerator: uint16
    denominator: uint16
    destination: address
}

// ---------------- DNS records ----------------
struct (0x4eb1f0f9) ChangeDnsRecord {
    queryId: uint64
    key: uint256
    value: RemainingBitsAndRefs
}

struct (0x1a0b9d51) EditContent {
    queryId: uint64
    newContent: Cell<DnsRecords>
}

struct (0xba93) DnsNextResolver {
    resolver: address
}

// ---------------- Factory (Tier 0) ----------------
struct (0x6c0c4b17) LockCollection {
    deploymentId: uint64 = 0
    queryId: uint64
    parentDomain: address
    admin: address
    isLinked: bool
    meta: Cell<CollectionMeta>
}

// Authenticated collection deployment acknowledgement.
struct (0x52445931) CollectionReady {
    deploymentId: uint64
    queryId: uint64
    parentDomain: address
    admin: address
    currentAdmin: address
    isLinked: bool
    isNew: bool
}

// Confirms that the canonical parent completed a Locked handoff.
struct (0x48444f4b) ParentHandoffComplete {
    deploymentId: uint64
    queryId: uint64
    parentDomain: address
    intendedAdmin: address
}

// Recovery probe bound to a persisted handoff generation.
struct (0x48445052) ConfirmParentHandoff {
    deploymentId: uint64
    queryId: uint64
    parentDomain: address
    intendedAdmin: address
}

// Admin-funded replay of the factory's stored pending phase.
struct (0x52545259) RetryCollectionDeployment {
    queryId: uint64
    collectionAddress: address
}

// Linked create; the parent owner connects it later through next_resolver.
struct (0x4c494e4b) CreateLinkedCollection {
    queryId: uint64
    parentDomain: address
    admin: address
    meta: Cell<CollectionMeta>
}

// Generation proof forwarded through the parent during a Locked handoff.
struct (0x48414e44) FactoryHandoff {
    deploymentId: uint64 = 0
    requestQueryId: uint64 = 0
    intendedAdmin: address
}

fun parseFactoryHandoffPayload(payload: TransferForwardPayload): FactoryHandoff? {
    var p = payload;
    try {
        val payloadInRef = p.loadBool();
        if (!payloadInRef) {
            return FactoryHandoff.fromSlice(p);
        }
        if (p.remainingBitsCount() != 0 || p.remainingRefsCount() != 1) {
            return null;
        }
        return FactoryHandoff.fromCell(p.loadRef());
    } catch {
        return null;
    }
}

// ---------------- Collection (Tier 1) ----------------
struct (0x2428aaa6) SubdomainInit {
    queryId: uint64
    index: uint256
    minter: address
    label: Cell<RemainingBitsAndRefs>
    setWalletToMinter: bool
    content: cell
}

struct (0x49524459) ItemReady {
    queryId: uint64
    index: uint256
    minter: address
}

struct (0x49278399) RegisterSubdomain {
    queryId: uint64
    label: Cell<RemainingBitsAndRefs> // bare label bytes, e.g. "alice" (no trailing \0)
    setWalletToMinter: bool
    content: cell
}

struct (0x1e4b7535) WithdrawFees {
    queryId: uint64
    amount: coins // 0 means max
}

struct (0x2b8af82e) TransferAdmin {
    queryId: uint64
    newAdmin: address
}

struct (0x9f3acb9c) AdminAssigned {
    queryId: uint64
    prevAdmin: address
}

struct (0x97be5c56) ProxyEditParentRecord {
    queryId: uint64
    key: uint256
    value: RemainingBitsAndRefs
}

struct (0x5cfedae5) FillUpParent {
    queryId: uint64
}

struct (0xe0329a90) EnforceResolver {
    queryId: uint64
}

struct (0xccef6e14) SetLabelReserved {
    queryId: uint64
    labelHash: uint256
    reserved: bool
}

struct (0x2096dda6) RescueNft {
    queryId: uint64
    nftAddress: address
    toAddress: address
}

struct (0x41434353) SetAccessMode {
    queryId: uint64
    accessMode: uint8
}

struct (0x414c4c57) SetAllowlistEntry {
    queryId: uint64
    wallet: address
    allowed: bool
}

struct (0x52505254) RetryParentReturn {
    queryId: uint64
}

struct (0x434d494e) ConfirmMint {
    queryId: uint64
    index: uint256
}

// This struct is placed in the TEP-62 forward_payload, normally behind the Either ref bit.
struct (0x4c4e4b33) LinkedParentAction {
    action: uint8
}
