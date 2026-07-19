// Economics: right-sized item deposit + buyer refund of overpayment (see economics audit).
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/dns-utils"
import "@contracts/errors"
import "@contracts/messages"
import "@contracts/prices"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "@wrappers/SubdomainItem.gen"
import "test-utils"

// "alice" = 5 chars -> default price 5 TON. Required = price + deploy + buffer.
const ALICE_PRICE = ton("5")
const REQUIRED = ALICE_PRICE + ITEM_DEPLOY_COST + MINT_FEE_BUFFER
const TEN_YEARS = 10 * 365 * 24 * 60 * 60

fun zeroPriceConfig(): PriceConfig {
    return {
        minChars: 1,
        p1: 0,
        p2: 0,
        p3: 0,
        p4: 0,
        p5: 0,
        p6: 0,
        p7: 0,
        p8: 0,
        p9: 0,
        p10: 0,
        pRest: 0,
    };
}

fun deployFreeCollection(isLinked: bool): (SubdomainCollection, Treasury, Treasury, Treasury) {
    val master = newActor("free-master", ton("100"));
    val parent = newActor("free-parent", ton("100"));
    val owner = newActor("free-owner", ton("100"));
    val user = newActor("free-user", ton("100"));
    val coll = SubdomainCollection.fromStorage({
        master: master.address,
        parentDomain: parent.address,
        isLinked,
        linkedAdmin: isLinked ? owner.address : master.address,
    });
    coll.deploy(master.address, { value: ton("0.05"), bounce: false });
    val meta: CollectionMeta = {
        priceConfig: zeroPriceConfig().toCell(),
        collectionContent: beginCell().endCell(),
        itemContentBaseUri: beginCell().endCell(),
    };
    val locked = coll.sendAny(
        master.address,
        LockCollection {
            queryId: 1,
            parentDomain: parent.address,
            admin: owner.address,
            isLinked,
            meta: meta.toCell(),
        }.toCell(),
        { value: ton("1"), bounce: false },
    );
    expect(locked).toHaveSuccessfulTx({ to: coll.address });
    return (coll, parent, owner, user);
}

fun internalMessageValue(tx: TlbTransaction): coins {
    val info = tx.loadInMsg<RemainingBitsAndRefs>().info;
    match (info) {
        TlbInternalMessage => return info.value.grams,
        TlbExternalInMessageInfo => throw 0,
        TlbExternalOutMessageInfo => throw 0,
    }
}

get fun `test economics: a freshly-minted item holds the small deposit, not 1 TON`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _res) = mintSubdomain(coll, user, "alice"); // helper overpays (20 TON)

    // The item keeps the small deployment reserve, not the old 1.1/1 TON of dead capital.
    val bal = testing.getAccountBalance(item.address);
    expect(bal > ton("0.04")).toEqual(true);
    expect(bal < ton("0.1")).toEqual(true);
}

get fun `test economics: overpayment is refunded to the buyer (only the price is kept)`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();

    // Send 20 TON for a 5 TON name; the ~14.9 excess must come back to the buyer.
    val before = testing.getAccountBalance(user.address);
    val (item, res) = mintSubdomain(coll, user, "alice", ton("20"));
    expect(testing.isDeployed(item.address)).toEqual(true);

    // a refund message went back to the buyer...
    expect(res).toHaveSuccessfulTx({ from: coll.address, to: user.address });

    // ...crediting back the overpayment above the quoted price and execution funding.
    val refundReceived = testing.getAccountBalance(user.address) - before;
    expect(refundReceived > ton("14.85")).toEqual(true);
    expect(refundReceived < ton("14.95")).toEqual(true);
}

get fun `test economics: exact funding mints with no refund`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();

    // Send exactly price + deploy + buffer; refund is 0 so no buyer-bound message.
    val (item, res) = mintSubdomain(coll, user, "alice", REQUIRED);
    expect(testing.isDeployed(item.address)).toEqual(true);
    expect(res.findTransaction({ from: coll.address, to: user.address })).toEqual(null);
}

get fun `test economics: under the price+deploy+buffer floor is rejected`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();

    val res = coll.sendRegisterSubdomain(
        user.address,
        7,
        labelSlice("alice"),
        true,
        { value: REQUIRED - ton("0.01"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_MINT_VALUE });
}

get fun `test economics: admin withdraws real revenue (no longer stranded by a 1 TON floor)`() {
    val (coll, _parent, owner, user) = deployLockedCollection();
    mintSubdomain(coll, user, "alice", ton("20")); // 5 TON price now sits on the collection

    // Old keep was 1.07 TON, so withdraw returned ~0 for cheap sales. Now the admin collects the revenue.
    val before = testing.getAccountBalance(owner.address);
    val res = coll.sendWithdrawFees(owner.address, 1, 0, { value: ton("1"), bounce: true });
    expect(res).toHaveSuccessfulTx({ from: coll.address, to: owner.address });
    val after = testing.getAccountBalance(owner.address);
    expect(after > before).toEqual(true);
}

get fun `test v4 fees: free mint accepts the exact base quote and rejects one nanotON less`() {
    val (coll, _parent, _owner, user) = deployFreeCollection(false);
    val quote = coll.getMintQuote(user.address, 5);
    val exact = ITEM_DEPLOY_COST + MINT_FEE_BUFFER;
    expect(quote.allowed).toEqual(true);
    expect(quote.effectivePrice).toEqual(0);
    expect(quote.requiredValue).toEqual(exact);

    val underfunded = coll.sendRegisterSubdomain(
        user.address,
        10,
        labelSlice("alice"),
        true,
        { value: exact - 1, bounce: true },
    );
    expect(underfunded).toHaveFailedTx({
        to: coll.address,
        exitCode: ERROR_INSUFFICIENT_MINT_VALUE,
    });

    val balanceBefore = testing.getAccountBalance(coll.address);
    val exactMint = coll.sendRegisterSubdomain(
        user.address,
        11,
        labelSlice("alice"),
        true,
        { value: exact, bounce: true },
    );
    expect(exactMint).toHaveSuccessfulTx({ to: coll.address });
    expect(exactMint.findTransaction({ from: coll.address, deploy: true })).toBeNotNull();
    expect(exactMint.findTransaction({ from: coll.address, to: user.address })).toEqual(null);
    expect(testing.getAccountBalance(coll.address)).toBeGreaterOrEqual(balanceBefore);

    val item = SubdomainItem.fromAddress(coll.getNftAddressByIndex(labelIndex("alice")));
    val itemBalance = testing.getAccountBalance(item.address);
    val storageFee = testing.getAccountStorageFee(item.address, TEN_YEARS)!;
    expect(itemBalance).toBeGreater(MIN_TONS_FOR_STORAGE);
    expect(itemBalance).toBeGreater(storageFee);
}

get fun `test v4 fees: due Locked heartbeat adds exactly 0.01 TON to the quote`() {
    testing.setNow(1700000000);
    val (coll, parent, _owner, user) = deployFreeCollection(false);
    testing.setNow(1700000000 + PARENT_HEARTBEAT_INTERVAL + 1);

    val exact = ITEM_DEPLOY_COST + MINT_FEE_BUFFER + PARENT_HEARTBEAT_AMOUNT;
    expect(coll.getMintQuote(user.address, 5).requiredValue).toEqual(exact);
    val underfunded = coll.sendRegisterSubdomain(
        user.address,
        20,
        labelSlice("alice"),
        true,
        { value: exact - 1, bounce: true },
    );
    expect(underfunded).toHaveFailedTx({
        to: coll.address,
        exitCode: ERROR_INSUFFICIENT_MINT_VALUE,
    });

    val balanceBefore = testing.getAccountBalance(coll.address);
    val exactMint = coll.sendRegisterSubdomain(
        user.address,
        21,
        labelSlice("alice"),
        true,
        { value: exact, bounce: true },
    );
    expect(exactMint).toHaveSuccessfulTx({ to: coll.address });
    val heartbeat = exactMint.findTransaction({ from: coll.address, to: parent.address })!;
    expect(internalMessageValue(heartbeat)).toEqual(PARENT_HEARTBEAT_AMOUNT);
    expect(coll.getLastParentFillUp()).toEqual(1700000000 + PARENT_HEARTBEAT_INTERVAL + 1);
    expect(coll.getMintQuote(user.address, 5).requiredValue).toEqual(
        ITEM_DEPLOY_COST + MINT_FEE_BUFFER,
    );
    expect(testing.getAccountBalance(coll.address)).toBeGreaterOrEqual(balanceBefore);
}

get fun `test v4 fees: Linked mint never charges or sends the parent heartbeat`() {
    testing.setNow(1700000000);
    val (coll, parent, _owner, user) = deployFreeCollection(true);
    testing.setNow(1700000000 + PARENT_HEARTBEAT_INTERVAL * 10);
    val exact = ITEM_DEPLOY_COST + MINT_FEE_BUFFER;
    expect(coll.getMintQuote(user.address, 5).requiredValue).toEqual(exact);

    val minted = coll.sendRegisterSubdomain(
        user.address,
        30,
        labelSlice("alice"),
        true,
        { value: exact, bounce: true },
    );
    expect(minted).toHaveSuccessfulTx({ to: coll.address });
    expect(minted.findTransaction({ from: coll.address, to: parent.address })).toEqual(null);
}

get fun `test v4 fees: maximum label mints at the same exact base funding`() {
    val (coll, _parent, _owner, user) = deployFreeCollection(false);
    var labelBuilder = beginCell();
    repeat (MAX_DOMAIN_SIZE) {
        labelBuilder.storeUint(97, BYTE_SIZE);
    }
    val label = labelBuilder.endCell();
    val index = label.beginParse().hash();
    val exact = ITEM_DEPLOY_COST + MINT_FEE_BUFFER;
    val balanceBefore = testing.getAccountBalance(coll.address);

    val minted = coll.sendRegisterSubdomain(
        user.address,
        50,
        label.beginParse(),
        true,
        { value: exact, bounce: true },
    );
    expect(minted).toHaveSuccessfulTx({ to: coll.address });
    expect(testing.isDeployed(coll.getNftAddressByIndex(index))).toEqual(true);
    expect(coll.getIsMintPending(index)).toEqual(false);
    expect(coll.getMintedCount()).toEqual(1);
    expect(testing.getAccountBalance(coll.address)).toBeGreaterOrEqual(balanceBefore);
}
