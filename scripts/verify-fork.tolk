// Fork verification against a real mainnet .ton DnsItem, offline with no broadcast.
// Run: TONCENTER_MAINNET_API_KEY=... acton script scripts/verify-fork.tolk --fork-net mainnet
//
// Checks the standard resolver category, then exercises v3 CLAIM and CONVERT_LOCKED with the
// canonical parent contract and an exact 0.01 TON forward amount.
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@contracts/dns-utils"
import "@contracts/messages"
import "@contracts/prices"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"

struct DnsReply {
    prefixBits: int
    record: cell?
}

const RAW_NEXT_RESOLVER = "dns_next_resolver".toBase256() // the buggy v6 key, for contrast

fun dotSlice(): slice {
    return beginCell().storeUint(0, 8).endCell().beginParse();
}

// internal name "\0test" — TEP-81 requires the leading \0 separator, then the label ("test")
fun subTest(): slice {
    return beginCell().storeUint(0, 8).storeUint(0x74657374, 32).endCell().beginParse();
}

fun resolveCat(item: address, sub: slice, cat: int): cell? {
    return net.runGetMethod<DnsReply>(item, "dnsresolve", [sub, cat]).record;
}

fun parentData(parent: address): ItemNftDataReply {
    return net.runGetMethod(parent, "get_nft_data");
}

fun forkCollectionMeta(): CollectionMeta {
    return {
        priceConfig: defaultPriceConfig().toCell(),
        collectionContent: beginCell().endCell(),
        itemContentBaseUri: beginCell().endCell(),
    };
}

fun linkedAction(action: uint8): TransferForwardPayload {
    return beginCell()
        .storeBool(true)
        .storeRef(LinkedParentAction { action }.toCell())
        .endCell()
        .beginParse();
}

fun transferParent(
    parent: address,
    owner: address,
    collection: address,
    queryId: uint64,
    action: uint8,
) {
    val transfer = createMessage({
        bounce: true,
        value: ton("0.2"),
        dest: parent,
        body: TransferOwnership {
            queryId,
            transferData: {
                newOwnerAddress: collection,
                responseDestination: owner,
                customPayload: null,
                forwardAmount: MIN_PARENT_RETURN_VALUE,
                forwardPayload: linkedAction(action),
            },
        },
    });
    net.send(owner, transfer);
}

fun main() {
    val parent = address("EQBV7GD_sEy3EQeFEjxeEzDbidjHIHaM0RMtMmlkJmXHRPvY"); // real telegram-i00040.ton
    val owner = parentData(parent).ownerAddress!;

    println("== REAL mainnet telegram-i00040.ton (forked state) ==");
    println(
        "next_resolver under sha256 (standard) : {}",
        resolveCat(parent, dotSlice(), CAT_DNS_NEXT_RESOLVER) != null ? "FOUND" : "null  <- RED",
    );
    println(
        "next_resolver under raw bytes (v6 bug) : {}",
        resolveCat(parent, dotSlice(), RAW_NEXT_RESOLVER) != null
            ? "FOUND <- where the broken pin sits"
            : "null",
    );

    // Apply the standard sha256 resolver key while impersonating the forked owner.
    val body = beginCell()
        .storeUint(0x4eb1f0f9, 32) // op::change_dns_record (real .ton item)
        .storeUint(1, 64) // query_id
        .storeUint(CAT_DNS_NEXT_RESOLVER, 256) // <- OUR v7 key (sha256), the only thing we fixed
        .storeRef(owner.toNextResolver()) // value: dns_next_resolver -> collection
        .endCell();

    val resolverPinMessage = createMessage({
        bounce: false,
        value: ton("0.1"),
        dest: parent,
        body,
    });
    testing.processSingleTraceStep(owner, resolverPinMessage);

    println("\n== after applying the standard sha256 pin ==");
    println(
        "next_resolver under sha256 (standard) : {}",
        resolveCat(parent, dotSlice(), CAT_DNS_NEXT_RESOLVER) != null ? "FOUND <- GREEN" : "null",
    );

    // the real-world resolution path: a deeper subdomain now delegates instead of dead-ending
    val deeper = net.runGetMethod<DnsReply>(parent, "dnsresolve", [subTest(), 0]);
    println(
        "dnsresolve('test.<parent>') delegates : {}",
        deeper.record != null ? "next_resolver returned <- GREEN" : "null",
    );

    val master = testing.treasury("fork-v3-master");
    testing.topUp(master.address, ton("10"));
    val collection = SubdomainCollection.fromStorage({
        master: master.address,
        parentDomain: parent,
        isLinked: true,
        linkedAdmin: owner,
    });
    collection.deploy(master.address, { value: ton("1"), bounce: false });
    collection.sendAny(
        master.address,
        LockCollection {
            deploymentId: 1,
            queryId: 1,
            parentDomain: parent,
            admin: owner,
            isLinked: true,
            meta: forkCollectionMeta().toCell(),
        }.toCell(),
        { value: ton("1"), bounce: false },
    );
    assert (collection.getIsLinked()) throw 1001;

    transferParent(parent, owner, collection.address, 2, LINKED_ACTION_CLAIM);
    assert (parentData(parent).ownerAddress! == owner) throw 1002;
    assert (collection.getAdmin()! == owner) throw 1003;
    assert (collection.getIsLinked()) throw 1004;
    assert (!collection.getParentReturn().pending) throw 1005;
    println("CLAIM at 0.01 TON                    : parent returned <- GREEN");

    transferParent(parent, owner, collection.address, 3, LINKED_ACTION_CONVERT_LOCKED);
    assert (parentData(parent).ownerAddress! == collection.address) throw 1006;
    assert (collection.getAdmin()! == owner) throw 1007;
    assert (!collection.getIsLinked()) throw 1008;
    assert (!collection.getParentReturn().pending) throw 1009;
    println("CONVERT_LOCKED at 0.01 TON           : collection owns parent <- GREEN");
}
