// Regression tests for the elite-grade hardening pass (review findings).
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
import "@wrappers/SubdomainItem.gen"
import "test-utils"

// #1 mint-brick: a masterchain minter is rejected in compute (refund), so the label is never
// marked minted with no item behind it.
get fun `test elite: masterchain minter is rejected, label stays free`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val mc = address.fromWorkchainAndHash(MASTERCHAIN, labelIndex("mc"));

    val res = coll.sendRegisterSubdomain(
        mc,
        7,
        labelSlice("alice"),
        true,
        null,
        { value: ton("20"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_WRONG_WORKCHAIN });

    // the slot is untouched: a normal basechain mint of the same label still works
    val (item, _r) = mintSubdomain(coll, user, "alice");
    expect(testing.isDeployed(item.address)).toEqual(true);
}

// #1 mint-brick: malformed initialRecords fail at the collection (before minted.set), not as a
// bounced item deploy that would brick the slot.
get fun `test elite: malformed initialRecords are rejected before minting`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val badRecords = beginCell()
        .storeUint(1, BYTE_SIZE)
        .endCell() as Cell<DnsRecords>;                                                 // tag != 0x00

    val res = coll.sendRegisterSubdomain(
        user.address,
        7,
        labelSlice("alice"),
        true,
        badRecords,
        { value: ton("20"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_CONTENT_TAG_INVALID });

    val (item, _r) = mintSubdomain(coll, user, "alice");
    expect(testing.isDeployed(item.address)).toEqual(true);
}

// v3 supports protocol-free collections while keeping deployment funding mandatory.
get fun `test elite: factory deploys a zero-price collection`() {
    val owner = newActor("dgo");
    val parent = newActor("dgp");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val freeGrid: PriceConfig = {
        minChars: 4,
        p1: ton("0"),
        p2: ton("0"),
        p3: ton("0"),
        p4: ton("0"),
        p5: ton("0"),
        p6: ton("0"),
        p7: ton("0"),
        p8: ton("0"),
        p9: ton("0"),
        p10: ton("0"),
        pRest: ton("0"),
    };
    val freeMeta: CollectionMeta = {
        priceConfig: freeGrid.toCell(),
        collectionContent: beginCell().endCell(),
        itemContentBaseUri: beginCell().endCell(),
    };
    val payload = beginCell().storeRef(freeMeta.toCell()).endCell().beginParse();

    val res = factory.sendOwnershipAssigned(
        parent.address,
        1,
        owner.address,
        payload,
        { value: ton("0.5"), bounce: false },
    );
    expect(res.findTransaction({ deploy: true })).toBeNotNull();
}

// #3 EnforceResolver: the caller must fund the pin, otherwise it would drain the collection.
get fun `test elite: enforce_resolver requires the caller to fund the pin`() {
    val (coll, parent, _owner, user) = deployLockedCollection();

    val low = coll.sendEnforceResolver(user.address, 1, { value: ton("0.05"), bounce: true });
    expect(low).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_BALANCE });

    val ok = coll.sendEnforceResolver(user.address, 2, { value: ton("0.2"), bounce: true });
    expect(ok).toHaveSuccessfulTx({ to: coll.address });
    expect(ok.findTransaction({ from: coll.address, to: parent.address })).toBeNotNull();
}

// #5 admin guard: a masterchain new admin is rejected (would otherwise brick all admin ops).
get fun `test elite: transfer_admin rejects a masterchain admin`() {
    val (coll, _parent, owner, _user) = deployLockedCollection();
    val mc = address.fromWorkchainAndHash(MASTERCHAIN, labelIndex("mcadmin"));

    val res = coll.sendTransferAdmin(owner.address, 1, mc, { value: ton("1"), bounce: true });
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_WRONG_WORKCHAIN });
    expect(coll.getAdmin()).toEqual(owner.address); // unchanged
}

// #11 TEP-66: conformant 0% royalty, getter + message reply.
get fun `test elite: TEP-66 royalty params are exposed (0%, conformant)`() {
    val (coll, _parent, owner, user) = deployLockedCollection();

    val (num, den, dest) = coll.royaltyParams();
    expect(num).toEqual(0);
    expect(den).toEqual(1000);
    expect(dest).toEqual(owner.address);

    val res = coll.sendGetRoyaltyParams(user.address, 1, { value: ton("0.1"), bounce: true });
    expect(res).toHaveSuccessfulTx({ to: coll.address });
    expect(
        res.findTransaction<ReportRoyaltyParams>({ from: coll.address, to: user.address }),
    ).toBeNotNull();
}

// security: a .ton owned by a masterchain wallet must be refunded at create, never stranded.
// The admin-workchain check lives in the factory (non-throwing, pre-handoff), NOT in the collection
// lock (which would throw after the .ton was already dispatched -> strand, the v2 incident class).
get fun `test elite: masterchain-owned .ton is refunded, not stranded`() {
    val parent = newActor("mcp");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(parent.address, { value: ton("1"), bounce: false });

    val mcAdmin = address.fromWorkchainAndHash(MASTERCHAIN, labelIndex("mcown"));
    val payload = beginCell()
        .storeRef(makeMeta().toCell())
        .endCell()
        .beginParse();                                                              // valid grid + funding

    val res = factory.sendOwnershipAssigned(
        parent.address,
        1,
        mcAdmin,
        payload,
        { value: ton("0.5"), bounce: false },
    );
    expect(
        res.findTransaction<TransferOwnership>({ from: factory.address, to: parent.address }),
    ).toBeNotNull();
    expect(res.findTransaction({ from: factory.address, deploy: true })).toEqual(null);
}

// A Locked create is only meaningful for a basechain TON DNS item. Treat an impossible sender
// workchain exactly like other recoverable create validation failures: return custody and deploy
// nothing instead of deriving an unusable collection address.
get fun `test elite: masterchain parent is refunded and never deployed`() {
    val owner = newActor("mc-parent-owner");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val mcParent = address.fromWorkchainAndHash(MASTERCHAIN, labelIndex("mc-parent"));
    val payload = beginCell().storeRef(makeMeta().toCell()).endCell().beginParse();
    val res = factory.sendOwnershipAssigned(
        mcParent,
        2,
        owner.address,
        payload,
        { value: ton("0.5"), bounce: false },
    );

    expect(
        res.findTransaction<TransferOwnership>({ from: factory.address, to: mcParent }),
    ).toBeNotNull();
    expect(res.findTransaction({ from: factory.address, deploy: true })).toEqual(null);
}
