// Regression tests for the elite-grade hardening pass (review findings).
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
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
        testOnchainMetadata(),
        { value: ton("20"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_WRONG_WORKCHAIN });

    // the slot is untouched: a normal basechain mint of the same label still works
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
    var freeMeta = makeMeta();
    freeMeta.priceConfig = freeGrid.toCell();
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

    val low = coll.sendEnforceResolver(
        user.address,
        1,
        { value: RESOLVER_PIN_FUND - 1, bounce: true },
    );
    expect(low).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_BALANCE });

    val ok = coll.sendEnforceResolver(
        user.address,
        2,
        { value: RESOLVER_PIN_FUND, bounce: true },
    );
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

get fun `test elite: item rejects a missing TEP-62 Either selector`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _mint) = mintSubdomain(coll, user, "alice");
    val buyer = newActor("tep62-missing-buyer");
    val malformed: TransferOwnership = {
        queryId: 1,
        transferData: {
            newOwnerAddress: buyer.address,
            responseDestination: user.address,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: emptyPayload(),
        },
    };

    val result = item.sendAny(
        user.address,
        malformed.toCell(),
        { value: ton("0.2"), bounce: true },
    );
    expect(result).toHaveFailedTx({
        to: item.address,
        exitCode: ERROR_INCORRECT_FORWARD_PAYLOAD,
    });
    expect(item.getEditor()).toEqual(user.address);
}

get fun `test elite: item rejects a malformed TEP-62 ref payload`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _mint) = mintSubdomain(coll, user, "alice");
    val buyer = newActor("tep62-malformed-buyer");
    val malformedPayload = beginCell()
        .storeBool(true)
        .storeUint(1, 1)
        .storeRef(beginCell().endCell())
        .endCell()
        .beginParse();

    val result = item.sendTransferOwnership(
        user.address,
        2,
        {
            newOwnerAddress: buyer.address,
            responseDestination: user.address,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: malformedPayload,
        },
        { value: ton("0.2"), bounce: true },
    );
    expect(result).toHaveFailedTx({
        to: item.address,
        exitCode: ERROR_INCORRECT_FORWARD_PAYLOAD,
    });
    expect(item.getEditor()).toEqual(user.address);
}

get fun `test elite: item accepts a valid TEP-62 ref payload`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _mint) = mintSubdomain(coll, user, "alice");
    val buyer = newActor("tep62-ref-buyer");
    val payload = beginCell()
        .storeBool(true)
        .storeRef(beginCell().storeUint(0xfeed, 16).endCell())
        .endCell()
        .beginParse();

    val result = item.sendTransferOwnership(
        user.address,
        3,
        {
            newOwnerAddress: buyer.address,
            responseDestination: user.address,
            customPayload: null,
            forwardAmount: ton("0.01"),
            forwardPayload: payload,
        },
        { value: ton("0.2"), bounce: true },
    );
    expect(result).toHaveSuccessfulTx({ to: item.address });
    expect(result).toHaveSuccessfulTx({ from: item.address, to: buyer.address });
    expect(item.getEditor()).toEqual(buyer.address);
}

get fun `test elite: rescue interoperates with a strict TEP-62 item`() {
    val (coll, _parent, owner, user) = deployLockedCollection();
    val (item, _mint) = mintSubdomain(coll, user, "alice");

    val deposit = item.sendTransferOwnership(
        user.address,
        3,
        makeTransferData(coll.address, user.address, 0),
        { value: ton("0.2"), bounce: true },
    );
    expect(deposit).toHaveSuccessfulTx({ to: item.address });
    expect(item.getEditor()).toEqual(coll.address);

    val rescue = coll.sendRescueNft(
        owner.address,
        4,
        item.address,
        user.address,
        { value: ton("0.2"), bounce: true },
    );
    expect(rescue).toHaveSuccessfulTx({ from: coll.address, to: item.address });
    expect(item.getEditor()).toEqual(user.address);
}

get fun `test elite: mint quote rejects a masterchain wallet`() {
    val (coll, _parent, _owner, _user) = deployLockedCollection();
    val masterchainWallet = address.fromWorkchainAndHash(
        MASTERCHAIN,
        labelIndex("quote-masterchain"),
    );

    val quote = coll.getMintQuote(masterchainWallet, 5);
    expect(quote.allowed).toEqual(false);
    expect(quote.effectivePrice).toEqual(ton("5"));
    expect(quote.requiredValue).toEqual(ton("5") + ITEM_DEPLOY_COST + MINT_FEE_BUFFER);
}
