// Fork verification against a real mainnet Telegram Username NFT, with no broadcast.
// Run: acton script scripts/verify-telemint-fork.tolk --fork-net mainnet --fork-block-number 80702445
// Telemint source: TelegramMessenger/telemint@1e47b28ac80608f4b5da2cdf2b60105da262ffcc.
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/dns-utils"
import "@contracts/errors"
import "@contracts/messages"
import "@contracts/prices"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "@wrappers/SubdomainFactory.gen"

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

fun usernameSlice(): slice {
    return beginCell()
        .storeUint(0, 8)
        .storeUint(0x6b617472696e616b616966, 88)
        .storeUint(0, 8)
        .endCell()
        .beginParse();
}

fun parentData(parent: address): ItemNftDataReply {
    return net.runGetMethod(parent, "get_nft_data");
}

fun metadata(): cell {
    return beginCell().storeUint(0, BYTE_SIZE).storeBool(false).endCell();
}

fun collectionMeta(): CollectionMeta {
    return {
        priceConfig: defaultPriceConfig().toCell(),
        autoRenewParent: false,
        collectionContent: metadata(),
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

fun returnParent(parent: address, currentOwner: address, recipient: address, queryId: uint64) {
    transferParent(
        parent,
        currentOwner,
        recipient,
        recipient,
        0,
        beginCell().storeBool(false).endCell().beginParse(),
        queryId,
    );
}

fun main() {
    val parent = address("0:8f76b98377b90a50bdfc1cd7d16751dc7f5f998ec05e1f0ae24552760d833b7d");
    val telegramCollection = address("0:80d78a35f955a14b679faa887ff4cd5bfc0f43b4a4eea2a7e6927f3701b273c2");
    val originalOwner = parentData(parent).ownerAddress!;
    testing.topUp(originalOwner, ton("20"));

    val master = testing.treasury("telemint-v5-master");
    val linked = SubdomainCollection.fromStorage({
        master: master.address,
        parentDomain: parent,
        isLinked: true,
        linkedAdmin: originalOwner,
    });
    linked.deploy(master.address, { value: ton("1"), bounce: false });
    linked.sendAny(
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
        body: ChangeDnsRecord {
            queryId: 2,
            key: CAT_DNS_NEXT_RESOLVER,
            value: beginCell().storeRef(linked.address.toNextResolver()).endCell().beginParse(),
        },
    });
    expect(net.send(originalOwner, resolverPin)).toHaveSuccessfulTx({ to: parent });

    val usernameRecord = net
        .runGetMethod<DnsReply>(telegramCollection, "dnsresolve", [usernameSlice(), 0])
        .record!;
    assert (DnsNextResolver.fromCell(usernameRecord).resolver == parent) throw 2001;
    val linkedRecord = net
        .runGetMethod<DnsReply>(parent, "dnsresolve", [dotSlice(), CAT_DNS_NEXT_RESOLVER])
        .record!;
    assert (DnsNextResolver.fromCell(linkedRecord).resolver == linked.address) throw 2002;

    transferParent(
        parent,
        originalOwner,
        linked.address,
        originalOwner,
        MIN_PARENT_RETURN_VALUE,
        linkedAction(LINKED_ACTION_CLAIM),
        3,
    );
    assert (parentData(parent).ownerAddress! == originalOwner) throw 2003;
    assert (linked.getAdmin()! == originalOwner) throw 2004;

    val buyer = testing.treasury("telemint-v5-buyer");
    returnParent(parent, originalOwner, buyer.address, 4);
    assert (parentData(parent).ownerAddress! == buyer.address) throw 2005;
    transferParent(
        parent,
        buyer.address,
        linked.address,
        buyer.address,
        MIN_PARENT_RETURN_VALUE,
        linkedAction(LINKED_ACTION_CLAIM),
        5,
    );
    assert (parentData(parent).ownerAddress! == buyer.address) throw 2006;
    assert (linked.getAdmin()! == buyer.address) throw 2007;

    transferParent(
        parent,
        buyer.address,
        linked.address,
        buyer.address,
        MIN_PARENT_RETURN_VALUE,
        linkedAction(LINKED_ACTION_CONVERT_LOCKED),
        6,
    );
    assert (parentData(parent).ownerAddress! == linked.address) throw 2008;
    assert (!linked.getIsLinked()) throw 2009;
    assert (!linked.getAutoRenewParent()) throw 2010;

    returnParent(parent, linked.address, buyer.address, 7);
    assert (parentData(parent).ownerAddress! == buyer.address) throw 2011;

    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(master.address, { value: ton("0.1"), bounce: false });
    val lockedAddress = factory.getCollectionAddress(parent);
    val createLocked = createMessage({
        bounce: true,
        value: ton("0.3"),
        dest: parent,
        body: TransferOwnership {
            queryId: 8,
            transferData: {
                newOwnerAddress: factory.address,
                responseDestination: buyer.address,
                customPayload: null,
                forwardAmount: MIN_CREATE_VALUE,
                forwardPayload: beginCell()
                    .storeBool(true)
                    .storeRef(collectionMeta().toCell())
                    .endCell()
                    .beginParse(),
            },
        },
    });
    net.send(buyer.address, createLocked);

    assert (testing.isDeployed(lockedAddress)) throw 2012;
    val locked = SubdomainCollection.fromAddress(lockedAddress);
    assert (locked.getAdmin()! == buyer.address) throw 2013;
    assert (!locked.getIsLinked()) throw 2014;
    assert (!locked.getAutoRenewParent()) throw 2015;
    assert (parentData(parent).ownerAddress! == lockedAddress) throw 2016;

    val lockedRecord = net
        .runGetMethod<DnsReply>(parent, "dnsresolve", [dotSlice(), CAT_DNS_NEXT_RESOLVER])
        .record!;
    assert (DnsNextResolver.fromCell(lockedRecord).resolver == lockedAddress) throw 2017;

    val minter = testing.treasury("telemint-v5-minter");
    testing.setNow(blockchain.now() + PARENT_HEARTBEAT_INTERVAL * 2);
    val quote = locked.getMintQuote(minter.address, 5);
    val minted = locked.sendRegisterSubdomain(
        minter.address,
        9,
        beginCell().storeUint(0x616c696365, 40).endCell().beginParse(),
        true,
        metadata(),
        { value: quote.requiredValue, bounce: true },
    );
    expect(minted).toHaveSuccessfulTx({ to: locked.address });
    expect(minted.findTransaction({ from: locked.address, to: parent })).toEqual(null);
    assert (
        quote.requiredValue == quote.effectivePrice + ITEM_DEPLOY_COST + MINT_FEE_BUFFER
    ) throw 2018;

    val renewal = locked.sendFillUpParent(
        minter.address,
        10,
        { value: MIN_PARENT_FILL, bounce: true },
    );
    expect(renewal).toHaveFailedTx({
        to: locked.address,
        exitCode: ERROR_PARENT_RENEWAL_DISABLED,
    });
    expect(renewal.findTransaction({ from: locked.address, to: parent })).toEqual(null);

    val childRecord = net.runGetMethod<DnsReply>(parent, "dnsresolve", [childSlice(), 0]).record!;
    assert (DnsNextResolver.fromCell(childRecord).resolver == lockedAddress) throw 2019;

    println("Telemint Linked claim              : GREEN");
    println("Telemint Linked -> Locked          : GREEN");
    println("Telemint Factory Locked handoff    : GREEN");
    println("Telemint Locked resolver           : GREEN");
    println("Telemint mint without heartbeat    : GREEN");
    println("Telemint explicit renewal disabled : GREEN");
}
