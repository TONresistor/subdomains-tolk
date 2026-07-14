// Shared test fixtures for the subdomain platform.
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "@contracts/dns-utils"
import "@contracts/messages"
import "@contracts/prices"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "@wrappers/SubdomainItem.gen"

fun newActor(name: string, topUp: coins = ton("1000")): Treasury {
    val actor = testing.treasury(name);
    if (topUp > 0) {
        testing.topUp(actor.address, topUp);
    }
    return actor;
}

// bare label bytes, e.g. "alice" -> 40-bit slice (for register_subdomain)
fun labelSlice(label: string): slice {
    return label.beginParse();
}

fun labelIndex(label: string): uint256 {
    return label.beginParse().hash();
}

// "alice" -> "alice\0"  (internal name form for dnsresolve)
fun makeLabelDomainSlice(label: string): slice {
    return beginCell()
        .storeSlice(label.beginParse())
        .storeUint(0, BYTE_SIZE)
        .endCell()
        .beginParse();
}

// prepend a leading \0
fun makeLeadingZero(domain: slice): slice {
    return beginCell().storeUint(0, BYTE_SIZE).storeSlice(domain).endCell().beginParse();
}

fun makeDotSlice(): slice {
    return beginCell().storeUint(0, BYTE_SIZE).endCell().beginParse();
}

fun emptyPayload(): RemainingBitsAndRefs {
    return beginCell().endCell().beginParse();
}

fun linkedActionPayload(
    action: uint8,
    target: address? = null,
    amount: coins = 0,
): RemainingBitsAndRefs {
    return beginCell()
        .storeBool(true)
        .storeRef(LinkedParentAction { action, target, amount }.toCell())
        .endCell()
        .beginParse();
}

fun parseNextResolverCell(data: cell): address {
    return DnsNextResolver.fromCell(data).resolver;
}

fun makeTransferData(
    newOwner: address,
    responseDestination: address?,
    forwardAmount: coins,
): TransferOwnershipData {
    return {
        newOwnerAddress: newOwner,
        responseDestination,
        customPayload: null,
        forwardAmount,
        forwardPayload: emptyPayload(),
    };
}

// A default CollectionMeta (default price grid, empty content). Stands in for the config the
// dApp builds and the factory relays in the create forward payload.
fun makeMeta(): CollectionMeta {
    return {
        priceConfig: defaultPriceConfig().toCell(),
        collectionContent: beginCell().endCell(),
        itemContentBaseUri: beginCell().endCell(),
    };
}

// 1-tx create: the factory deploys the collection directly locked (LockCollection from master).
// In unit tests we stand in for the factory with a "master" treasury sending LockCollection.
// Returns (collection, parentStandIn, admin, user).
fun deployLockedCollection(): (SubdomainCollection, Treasury, Treasury, Treasury) {
    val masterT = newActor("master", ton("100")); // stand-in for the factory (= master)
    val parent = newActor("parent", ton("100"));  // stand-in for the parent .ton DnsItem
    val owner = newActor("owner", ton("100"));    // previous parent owner -> admin
    val user = newActor("user", ton("10000"));

    val coll = SubdomainCollection.fromStorage({
        master: masterT.address,
        parentDomain: parent.address,
        isLinked: false,
        linkedAdmin: masterT.address,
    });
    coll.deploy(masterT.address, { value: ton("0.05"), bounce: false }); // bare skeleton
    expect(testing.isDeployed(coll.address)).toEqual(true);
    expect(coll.getAdmin()).toEqual(null);                               // not locked yet

    val lockRes = coll.sendAny(
        masterT.address,
        LockCollection {
            queryId: 1,
            parentDomain: parent.address,
            admin: owner.address,
            isLinked: false,
            meta: makeMeta().toCell(),
        }.toCell(),
        { value: ton("1"), bounce: false },
    );
    expect(lockRes).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getAdmin()).toEqual(owner.address);

    return (coll, parent, owner, user);
}

// Same as deployLockedCollection but in Linked (self-custody) mode: the skeleton carries
// isLinked=true, so the collection lives at its own address and never takes custody of the parent.
// The "owner" keeps the parent .ton; here `parent` stands in for that still-owner-held .ton.
fun deployLinkedCollection(): (SubdomainCollection, Treasury, Treasury, Treasury) {
    val masterT = newActor("master", ton("100"));
    val parent = newActor("parent", ton("100"));
    val owner = newActor("owner", ton("100"));
    val user = newActor("user", ton("10000"));

    val coll = SubdomainCollection.fromStorage({
        master: masterT.address,
        parentDomain: parent.address,
        isLinked: true,
        linkedAdmin: owner.address,
    });
    coll.deploy(masterT.address, { value: ton("0.05"), bounce: false });
    expect(coll.getIsLinked()).toEqual(false); // not locked yet -> default false

    val lockRes = coll.sendAny(
        masterT.address,
        LockCollection {
            queryId: 1,
            parentDomain: parent.address,
            admin: owner.address,
            isLinked: true,
            meta: makeMeta().toCell(),
        }.toCell(),
        { value: ton("1"), bounce: false },
    );
    expect(lockRes).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getAdmin()).toEqual(owner.address);
    expect(coll.getIsLinked()).toEqual(true); // self-custody mode

    return (coll, parent, owner, user);
}

// Registers `label` through `coll` and returns the deployed item wrapper.
fun mintSubdomain(
    coll: SubdomainCollection,
    minter: Treasury,
    label: string,
    value: coins = ton("20"),
): (SubdomainItem, SendResultList) {
    val res = coll.sendRegisterSubdomain(
        minter.address,
        7,
        labelSlice(label),
        true,
        null,
        { value, bounce: true },
    );
    val deployTx = res.findTransaction({ from: coll.address, deploy: true });
    expect(deployTx).toBeNotNull();
    val item = SubdomainItem.fromAddress(deployTx!.getAccountAddress());
    return (item, res);
}
