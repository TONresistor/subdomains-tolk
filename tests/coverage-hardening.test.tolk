// Coverage + mutation hardening: exercise price tiers, grid validation, label-validation
// boundaries, GetStaticData, record persistence, and unlocked getters.
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

fun gridPayload(grid: PriceConfig): RemainingBitsAndRefs {
    val meta: CollectionMeta = {
        priceConfig: grid.toCell(),
        collectionContent: beginCell().endCell(),
        itemContentBaseUri: beginCell().endCell(),
    };
    return beginCell().storeRef(meta.toCell()).endCell().beginParse();
}

fun sendCreate(grid: PriceConfig): SendResultList {
    val owner = newActor("cgo");
    val parent = newActor("cgp");
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });
    return factory.sendOwnershipAssigned(
        parent.address,
        1,
        owner.address,
        gridPayload(grid),
        { value: ton("0.5"), bounce: false },
    );
}

// every price tier is reachable and returns the configured value
get fun `test cover: price tiers map every label length`() {
    val (coll, _parent, _owner, _user) = deployLockedCollection();
    expect(coll.getPrice(1)).toEqual(ton("100"));
    expect(coll.getPrice(2)).toEqual(ton("50"));
    expect(coll.getPrice(3)).toEqual(ton("20"));
    expect(coll.getPrice(4)).toEqual(ton("10"));
    expect(coll.getPrice(5)).toEqual(ton("5"));
    expect(coll.getPrice(6)).toEqual(ton("4"));
    expect(coll.getPrice(7)).toEqual(ton("3"));
    expect(coll.getPrice(8)).toEqual(ton("2"));
    expect(coll.getPrice(9)).toEqual(ton("1"));
    expect(coll.getPrice(10)).toEqual(ton("0.5"));
    expect(coll.getPrice(11)).toEqual(ton("0.1"));
    expect(coll.getPrice(50)).toEqual(ton("0.1")); // 11+ clamps to pRest
}

// grid validation: a non-monotonic grid is refused at create (refund, no deploy)
get fun `test cover: create refuses a non-monotonic price grid`() {
    val nonMono: PriceConfig = {
        minChars: 4,
        p1: ton("10"),
        p2: ton("10"),
        p3: ton("10"),
        p4: ton("1"),
        p5: ton("10"),
        p6: ton("4"),
        p7: ton("3"),
        p8: ton("2"),
        p9: ton("1"),
        p10: ton("0.5"),
        pRest: ton("0.1"),
    };
    val res = sendCreate(nonMono);
    expect(res.findTransaction({ deploy: true })).toEqual(null);
}

// grid validation: a below-floor cheapest tier is refused
get fun `test cover: create refuses a grid below the price floor`() {
    val belowFloor: PriceConfig = {
        minChars: 4,
        p1: ton("100"),
        p2: ton("50"),
        p3: ton("20"),
        p4: ton("10"),
        p5: ton("5"),
        p6: ton("4"),
        p7: ton("3"),
        p8: ton("2"),
        p9: ton("1"),
        p10: ton("0.5"),
        pRest: ton("0.04"), // < MIN_NAME_PRICE 0.05
    };
    val res = sendCreate(belowFloor);
    expect(res.findTransaction({ deploy: true })).toEqual(null);
}

// a just-valid grid (cheapest exactly at the floor, monotonic) is accepted
get fun `test cover: create accepts a grid exactly at the floor`() {
    val atFloor: PriceConfig = {
        minChars: 4,
        p1: ton("0.05"),
        p2: ton("0.05"),
        p3: ton("0.05"),
        p4: ton("0.05"),
        p5: ton("0.05"),
        p6: ton("0.05"),
        p7: ton("0.05"),
        p8: ton("0.05"),
        p9: ton("0.05"),
        p10: ton("0.05"),
        pRest: ton("0.05"),
    };
    val res = sendCreate(atFloor);
    expect(res.findTransaction({ deploy: true })).toBeNotNull();
}

// a registry can set a custom minimum length (here 2): "ab" mints, "a" is rejected
get fun `test cover: registry can set a 2-char minimum`() {
    val masterT = newActor("m2", ton("100"));
    val parent = newActor("p2", ton("100"));
    val owner = newActor("o2", ton("100"));
    val user = newActor("u2", ton("10000"));
    val coll = SubdomainCollection.fromStorage({
        master: masterT.address,
        parentDomain: parent.address,
        isLinked: false,
        linkedAdmin: masterT.address,
    });
    coll.deploy(masterT.address, { value: ton("0.05"), bounce: false });

    val grid: PriceConfig = {
        minChars: 2,
        p1: ton("10"),
        p2: ton("10"),
        p3: ton("10"),
        p4: ton("10"),
        p5: ton("5"),
        p6: ton("4"),
        p7: ton("3"),
        p8: ton("2"),
        p9: ton("1"),
        p10: ton("0.5"),
        pRest: ton("0.1"),
    };
    val meta: CollectionMeta = {
        priceConfig: grid.toCell(),
        collectionContent: beginCell().endCell(),
        itemContentBaseUri: beginCell().endCell(),
    };
    coll.sendAny(
        masterT.address,
        LockCollection {
            queryId: 1,
            parentDomain: parent.address,
            admin: owner.address,
            isLinked: false,
            meta: meta.toCell(),
        }.toCell(),
        { value: ton("1"), bounce: false },
    );

    expect(coll.getMinChars()).toEqual(2);

    val (item, _r) = mintSubdomain(coll, user, "ab"); // 2 chars now allowed
    expect(testing.isDeployed(item.address)).toEqual(true);

    val one = coll.sendRegisterSubdomain(
        user.address,
        2,
        labelSlice("a"),
        true,
        null,
        { value: ton("50"), bounce: true },
    );
    expect(one).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_TOO_SHORT });
}

// an out-of-range minChars (here 5) is refused at create
get fun `test cover: create refuses an out-of-range minChars`() {
    val bad: PriceConfig = {
        minChars: 5, // > MAX_MIN_CHARS (4)
        p1: ton("100"),
        p2: ton("50"),
        p3: ton("20"),
        p4: ton("10"),
        p5: ton("5"),
        p6: ton("4"),
        p7: ton("3"),
        p8: ton("2"),
        p9: ton("1"),
        p10: ton("0.5"),
        pRest: ton("0.1"),
    };
    val res = sendCreate(bad);
    expect(res.findTransaction({ deploy: true })).toEqual(null);
}

// 1-char names price at their OWN tier (p1), distinct from the 4-char tier (p4)
get fun `test cover: short names price at their own tier`() {
    val masterT = newActor("m1", ton("100"));
    val parent = newActor("p1c", ton("100"));
    val owner = newActor("o1", ton("100"));
    val user = newActor("u1", ton("10000"));
    val coll = SubdomainCollection.fromStorage({
        master: masterT.address,
        parentDomain: parent.address,
        isLinked: false,
        linkedAdmin: masterT.address,
    });
    coll.deploy(masterT.address, { value: ton("0.05"), bounce: false });

    val grid: PriceConfig = {
        minChars: 1,
        p1: ton("50"),
        p2: ton("20"),
        p3: ton("15"),
        p4: ton("10"),
        p5: ton("5"),
        p6: ton("4"),
        p7: ton("3"),
        p8: ton("2"),
        p9: ton("1"),
        p10: ton("0.5"),
        pRest: ton("0.1"),
    };
    val meta: CollectionMeta = {
        priceConfig: grid.toCell(),
        collectionContent: beginCell().endCell(),
        itemContentBaseUri: beginCell().endCell(),
    };
    coll.sendAny(
        masterT.address,
        LockCollection {
            queryId: 1,
            parentDomain: parent.address,
            admin: owner.address,
            isLinked: false,
            meta: meta.toCell(),
        }.toCell(),
        { value: ton("1"), bounce: false },
    );

    expect(coll.getMinChars()).toEqual(1);
    expect(coll.getPrice(1)).toEqual(ton("50")); // p1, distinct from p4 (10)
    expect(coll.getPrice(3)).toEqual(ton("15")); // p3

    // funding below p1 is rejected; above it mints
    val low = coll.sendRegisterSubdomain(
        user.address,
        1,
        labelSlice("x"),
        true,
        null,
        { value: ton("40"), bounce: true },
    ); // < 50
    expect(low).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_MINT_VALUE });
    val (item, _r) = mintSubdomain(coll, user, "x", ton("60"));
    expect(testing.isDeployed(item.address)).toEqual(true);
}

// a label whose bit length is not a whole number of bytes is rejected
get fun `test cover: non-byte-aligned label is rejected`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    // Four otherwise-valid label bytes plus one trailing bit: without the explicit byte-alignment
    // assertion, checkDomainString would inspect only "abcd" and incorrectly accept this.
    val ragged = beginCell().storeSlice("abcd".beginParse()).storeUint(0, 1).endCell().beginParse();
    val res = coll.sendRegisterSubdomain(
        user.address,
        1,
        ragged,
        true,
        null,
        { value: ton("50"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_INVALID_CHARS });
}

// hyphen rules: rejected at the edge, allowed in the interior
get fun `test cover: hyphen allowed interior, rejected at the edge`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();

    val lead = coll.sendRegisterSubdomain(
        user.address,
        1,
        labelSlice("-abcd"),
        true,
        null,
        { value: ton("50"), bounce: true },
    );
    expect(lead).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_INVALID_CHARS });

    val (item, _r) = mintSubdomain(coll, user, "ab-cd"); // interior hyphen is fine
    expect(testing.isDeployed(item.address)).toEqual(true);
}

// GetStaticData (TEP-62) replies with ReportStaticData
get fun `test cover: item answers GetStaticData with ReportStaticData`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _r) = mintSubdomain(coll, user, "alice");

    val res = item.sendGetStaticData(user.address, 9, { value: ton("0.1"), bounce: true });
    expect(res).toHaveSuccessfulTx({ to: item.address });
    expect(
        res.findTransaction<ReportStaticData>({ from: item.address, to: user.address }),
    ).toBeNotNull();
}

// a record edit persists across messages (proves the item's setData is load-bearing)
get fun `test cover: an item record edit persists`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _r) = mintSubdomain(coll, user, "alice");

    val siteRec = beginCell().storeUint(0xad01, 16).endCell();
    val setRes = item.sendChangeDnsRecord(
        user.address,
        1,
        CAT_SITE,
        beginCell().storeRef(siteRec).endCell().beginParse(),
        { value: ton("0.1"), bounce: true },
    );
    expect(setRes).toHaveSuccessfulTx({ to: item.address });

    // read back in a separate query: the record is there
    expect(item.dnsresolve(makeDotSlice(), CAT_SITE).resolvedRecord).toBeNotNull();
}

// every read getter is safe on an unlocked (skeleton) collection
get fun `test cover: getters are safe on a skeleton collection`() {
    val masterT = newActor("skm", ton("10"));
    val parent = newActor("skp", ton("10"));
    val coll = SubdomainCollection.fromStorage({
        master: masterT.address,
        parentDomain: parent.address,
        isLinked: false,
        linkedAdmin: masterT.address,
    });
    coll.deploy(masterT.address, { value: ton("0.05"), bounce: false });
    expect(coll.isLocked()).toEqual(false);

    expect(coll.getAdmin()).toEqual(null);
    expect(coll.getMintedCount()).toEqual(0);
    expect(coll.getPrice(5)).toEqual(0);
    expect(coll.getLastParentFillUp()).toEqual(0);
    expect(coll.getParentDomain()).toEqual(parent.address); // skeleton still knows its parent
}

// dnsresolve routing math: apex resolves to self-without-record; a real label routes to its item
get fun `test cover: dnsresolve routing prefix lengths`() {
    val (coll, _parent, _owner, _user) = deployLockedCollection();

    // bare "." (single \0) = self, no record
    val apex = coll.dnsresolve(makeDotSlice(), 0);
    expect(apex.resolvedPrefixLengthBits).toEqual(8);
    expect(apex.resolvedRecord).toEqual(null);

    // "alice\0" routes to the item address with the label prefix consumed
    val routed = coll.dnsresolve(makeLabelDomainSlice("alice"), 0);
    expect(routed.resolvedPrefixLengthBits).toEqual(40); // 5 chars * 8 bits
    expect(routed.resolvedRecord).toBeNotNull();
    expect(parseNextResolverCell(routed.resolvedRecord!)).toEqual(
        coll.getNftAddressByIndex(labelIndex("alice")),
    );
}

// a locked collection refuses a second LockCollection (re-onboard safety: bounce:true returns the value)
get fun `test cover: a locked collection rejects a re-lock`() {
    val (coll, parent, owner, _user) = deployLockedCollection();
    val res = coll.sendAny(
        owner.address,
        LockCollection {
            queryId: 1,
            parentDomain: parent.address,
            admin: owner.address,
            isLinked: false,
            meta: makeMeta().toCell(),
        }.toCell(),
        { value: ton("1"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_NOT_FROM_MASTER });
    expect(coll.getAdmin()).toEqual(owner.address); // admin unchanged
}

// the factory safely ignores a bare value top-up (empty body)
get fun `test cover: factory ignores an empty-body top-up`() {
    val someone = newActor("ftu");
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(someone.address, { value: ton("1"), bounce: false });

    val res = factory.sendAny(
        someone.address,
        beginCell().endCell(),
        { value: ton("0.5"), bounce: false },
    );
    expect(res).toHaveSuccessfulTx({ to: factory.address });
    expect(factory.getDeployedCount()).toEqual(0);
    expect(res.findTransaction({ from: factory.address, deploy: true })).toEqual(null);
}

// the factory silently accepts an Excesses top-up (NFT change), no deploy
get fun `test cover: factory ignores an Excesses top-up`() {
    val someone = newActor("fex");
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(someone.address, { value: ton("1"), bounce: false });

    val res = factory.sendAny(
        someone.address,
        Excesses { queryId: 1 }.toCell(),
        { value: ton("0.5"), bounce: false },
    );
    expect(res).toHaveSuccessfulTx({ to: factory.address });
    expect(factory.getDeployedCount()).toEqual(0);
}

// a .ton transferred with NO config payload is refunded, never deployed-broken
get fun `test cover: factory refunds a transfer that carries no config`() {
    val owner = newActor("ncfo");
    val parent = newActor("ncfp");
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    // sufficient value, but the forward payload has no meta ref -> must refund (not deploy)
    val res = factory.sendOwnershipAssigned(
        parent.address,
        1,
        owner.address,
        emptyPayload(),
        { value: ton("0.5"), bounce: false },
    );
    expect(
        res.findTransaction<TransferOwnership>({ from: factory.address, to: parent.address }),
    ).toBeNotNull();
    expect(res.findTransaction({ from: factory.address, deploy: true })).toEqual(null);
    expect(factory.getDeployedCount()).toEqual(0);
}

// withdraw-all keeps only the small operating floor (no lease reserve); revenue is fully released
get fun `test cover: withdraw-all retains only the operating floor`() {
    val (coll, _parent, owner, user) = deployLockedCollection();
    mintSubdomain(coll, user, "alice", ton("20")); // 5 TON revenue retained

    val res = coll.sendWithdrawFees(owner.address, 1, 0, { value: ton("0.05"), bounce: true });
    expect(res).toHaveSuccessfulTx({ from: coll.address, to: owner.address });

    val kept = testing.getAccountBalance(coll.address);
    expect(
        kept >= COLLECTION_MIN_BALANCE,
    ).toEqual(true);                          // floor kept: collection stays operational
    expect(kept < ton("0.25")).toEqual(true); // the ~5 TON revenue left
}
