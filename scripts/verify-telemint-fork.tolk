// Fork verification against real mainnet Telegram Username NFTs, offline with no broadcast.
// Run: acton script scripts/verify-telemint-fork.tolk --fork-net mainnet --fork-block-number 80702445
// Telemint source reviewed at TelegramMessenger/telemint commit 1e47b28ac80608f4b5da2cdf2b60105da262ffcc.
//
// Checks Telemint DNS delegation and the complete Linked ownership round trip with the exact
// 0.05 TON outer value and 0.01 TON forward amount used by the production clients.
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/dns-utils"
import "@contracts/messages"
import "@contracts/prices"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"

const APP_PARENT_ACTION_VALUE = ton("0.05")

struct DnsReply {
    prefixBits: int
    record: cell?
}

fun dotSlice(): slice {
    return beginCell().storeUint(0, 8).endCell().beginParse();
}

fun childSlice(): slice {
    return beginCell().storeUint(0, 8).storeUint(0x616c696365, 40).endCell().beginParse();
}

// Internal TON DNS form for "katrinakaif\0", with the leading separator.
fun usernameSlice(): slice {
    return beginCell()
        .storeUint(0, 8)
        .storeUint(0x6b617472696e616b616966, 88)
        .storeUint(0, 8)
        .endCell()
        .beginParse();
}

fun collectionChildSlice(): slice {
    return beginCell()
        .storeUint(0, 8)
        .storeUint(0x616c696365, 40)
        .storeUint(0, 8)
        .endCell()
        .beginParse();
}

fun parentData(parent: address): ItemNftDataReply {
    return net.runGetMethod(parent, "get_nft_data");
}

fun collectionMeta(): CollectionMeta {
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
    sender: address,
    recipient: address,
    response: address,
    forwardAmount: coins,
    forwardPayload: TransferForwardPayload,
    queryId: uint64,
) {
    val transfer = createMessage({
        bounce: true,
        value: APP_PARENT_ACTION_VALUE,
        dest: parent,
        body: TransferOwnership {
            queryId,
            transferData: {
                newOwnerAddress: recipient,
                responseDestination: response,
                customPayload: null,
                forwardAmount,
                forwardPayload,
            },
        },
    });
    net.send(sender, transfer);
}

fun main() {
    // @katrinakaif, currently a wallet-owned Telegram Username NFT.
    val parent = address("0:8f76b98377b90a50bdfc1cd7d16751dc7f5f998ec05e1f0ae24552760d833b7d");
    val telegramCollection = address("0:80d78a35f955a14b679faa887ff4cd5bfc0f43b4a4eea2a7e6927f3701b273c2");
    val originalOwner = parentData(parent).ownerAddress!;
    testing.topUp(originalOwner, ton("10"));

    val master = testing.treasury("telemint-v5-master");
    val collection = SubdomainCollection.fromStorage({
        master: master.address,
        parentDomain: parent,
        isLinked: true,
        linkedAdmin: originalOwner,
    });
    collection.deploy(master.address, { value: ton("1"), bounce: false });
    collection.sendAny(
        master.address,
        LockCollection {
            deploymentId: 1,
            queryId: 1,
            parentDomain: parent,
            admin: originalOwner,
            isLinked: true,
            meta: collectionMeta().toCell(),
        }.toCell(),
        { value: ton("1"), bounce: false },
    );

    val resolverPin = createMessage({
        bounce: true,
        value: ton("0.1"),
        dest: parent,
        body: beginCell()
            .storeUint(0x4eb1f0f9, 32)
            .storeUint(2, 64)
            .storeUint(CAT_DNS_NEXT_RESOLVER, 256)
            .storeRef(collection.address.toNextResolver())
            .endCell(),
    });
    val resolverPinTrace = net.send(originalOwner, resolverPin);
    expect(resolverPinTrace).toHaveSuccessfulTx({ to: parent });

    val rootRecord = net
        .runGetMethod<DnsReply>(
            parent,
            "dnsresolve",
            [dotSlice(), CAT_DNS_NEXT_RESOLVER],
        )
        .record!;
    assert (DnsNextResolver.fromCell(rootRecord).resolver == collection.address) throw 2001;
    val childRecord = net.runGetMethod<DnsReply>(parent, "dnsresolve", [childSlice(), 0]).record!;
    assert (DnsNextResolver.fromCell(childRecord).resolver == collection.address) throw 2002;
    val usernameRecord = net
        .runGetMethod<DnsReply>(
            telegramCollection,
            "dnsresolve",
            [usernameSlice(), 0],
        )
        .record!;
    assert (DnsNextResolver.fromCell(usernameRecord).resolver == parent) throw 2003;
    val collectionRecord = net
        .runGetMethod<DnsReply>(
            collection.address,
            "dnsresolve",
            [collectionChildSlice(), 0],
        )
        .record;
    assert (collectionRecord != null) throw 2004;

    transferParent(
        parent,
        originalOwner,
        collection.address,
        originalOwner,
        MIN_PARENT_RETURN_VALUE,
        linkedAction(LINKED_ACTION_CLAIM),
        3,
    );
    assert (parentData(parent).ownerAddress! == originalOwner) throw 2005;
    assert (collection.getAdmin()! == originalOwner) throw 2006;
    assert (!collection.getParentReturn().pending) throw 2007;

    val buyer = testing.treasury("telemint-v5-buyer");
    transferParent(
        parent,
        originalOwner,
        buyer.address,
        originalOwner,
        0,
        beginCell().storeBool(false).endCell().beginParse(),
        4,
    );
    assert (parentData(parent).ownerAddress! == buyer.address) throw 2008;

    transferParent(
        parent,
        buyer.address,
        collection.address,
        buyer.address,
        MIN_PARENT_RETURN_VALUE,
        linkedAction(LINKED_ACTION_CLAIM),
        5,
    );
    assert (parentData(parent).ownerAddress! == buyer.address) throw 2009;
    assert (collection.getAdmin()! == buyer.address) throw 2010;
    assert (!collection.getParentReturn().pending) throw 2011;

    println("Telemint resolver pin              : GREEN");
    println("Telemint collection -> username   : GREEN");
    println("Telemint nested DNS delegation    : GREEN");
    println("Linked claim at 0.05 / 0.01 TON   : GREEN");
    println("Post-sale buyer claim             : GREEN");
}
