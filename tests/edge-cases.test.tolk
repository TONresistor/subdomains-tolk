import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/dns-utils"
import "@contracts/errors"
import "@contracts/messages"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "@wrappers/SubdomainItem.gen"
import "test-utils"

// ----------------------------------------------------------------- pricing

get fun `test price: tiers vary by label length`() {
    val (coll, _parent, _owner, _user) = deployLockedCollection();
    expect(coll.getPrice(4)).toEqual(ton("10"));
    expect(coll.getPrice(6)).toEqual(ton("4"));
    expect(coll.getPrice(9)).toEqual(ton("1"));
    expect(coll.getPrice(11)).toEqual(ton("0.1"));
    expect(coll.getPrice(50)).toEqual(ton("0.1")); // 11+ flat
}

get fun `test metadata: collection content is immutable after deployment`() {
    val (coll, _parent, owner, _user) = deployLockedCollection();
    val before = coll.getCollectionData().content.hash();
    val res = coll.sendSetAccessMode(
        owner.address,
        1,
        ACCESS_ADMIN_ONLY,
        { value: ton("0.05"), bounce: true },
    );
    expect(res).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getCollectionData().content.hash()).toEqual(before);
    expect(coll.getPrice(5)).toEqual(ton("5"));
}

// ----------------------------------------------------------------- admin ops

get fun `test admin: withdraw_fees pays the admin, non-admin rejected`() {
    val (coll, _parent, owner, user) = deployLockedCollection();
    mintSubdomain(coll, user, "alice"); // collection now holds the price as revenue

    val bad = coll.sendWithdrawFees(user.address, 1, 0, { value: ton("1"), bounce: true });
    expect(bad).toHaveFailedTx({ to: coll.address, exitCode: ERROR_NOT_ADMIN });

    val res = coll.sendWithdrawFees(owner.address, 2, 0, { value: ton("1"), bounce: true });
    expect(res).toHaveSuccessfulTx({ to: coll.address });
    expect(res.findTransaction({ from: coll.address, to: owner.address })).toBeNotNull();
}

get fun `test admin: proxy edit parent record (resolver forbidden, non-admin rejected)`() {
    val (coll, parent, owner, user) = deployLockedCollection();
    val recordVal = beginCell()
        .storeRef(beginCell().storeUint(0xad01, 16).endCell())
        .endCell()
        .beginParse();

    // admin edits a NON-resolver record -> relayed to the parent
    val ok = coll.sendProxyEditParentRecord(
        owner.address,
        1,
        CAT_SITE,
        recordVal,
        { value: ton("1"), bounce: true },
    );
    expect(ok).toHaveSuccessfulTx({ to: coll.address });
    expect(
        ok.findTransaction<ChangeDnsRecord>({ from: coll.address, to: parent.address }),
    ).toBeNotNull();

    // editing the resolver record is forbidden
    val forbidden = coll.sendProxyEditParentRecord(
        owner.address,
        2,
        CAT_DNS_NEXT_RESOLVER,
        recordVal,
        { value: ton("1"), bounce: true },
    );
    expect(forbidden).toHaveFailedTx({ to: coll.address, exitCode: ERROR_CANNOT_EDIT_RESOLVER });

    // non-admin rejected
    val bad = coll.sendProxyEditParentRecord(
        user.address,
        3,
        CAT_SITE,
        recordVal,
        { value: ton("1"), bounce: true },
    );
    expect(bad).toHaveFailedTx({ to: coll.address, exitCode: ERROR_NOT_ADMIN });
}

get fun `test rescue: a mis-routed (non-parent) NFT can be rescued by the admin`() {
    val (coll, _parent, owner, _user) = deployLockedCollection();
    val strayNft = newActor("strayNft");
    val res = coll.sendRescueNft(
        owner.address,
        1,
        strayNft.address,
        owner.address,
        { value: ton("1"), bounce: true },
    );
    expect(res).toHaveSuccessfulTx({ to: coll.address });
    expect(
        res.findTransaction<TransferOwnership>({ from: coll.address, to: strayNft.address }),
    ).toBeNotNull();
}

// ----------------------------------------------------------------- item records

get fun `test item: edit_content and change/delete dns record`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _res) = mintSubdomain(coll, user, "alice");

    // EditContent: replace the whole records map
    var recs: DnsRecords = [];
    recs.set(CAT_SITE, beginCell().storeUint(0xad01, 16).endCell());
    val edit = item.sendEditContent(user.address, 1, recs, { value: ton("1"), bounce: true });
    expect(edit).toHaveSuccessfulTx({ to: item.address });
    expect(item.dnsresolve(makeDotSlice(), CAT_SITE).resolvedRecord).toBeNotNull();

    // ChangeDnsRecord with no ref -> delete
    val emptyVal = beginCell().endCell().beginParse();
    val del = item.sendChangeDnsRecord(
        user.address,
        2,
        CAT_SITE,
        emptyVal,
        { value: ton("1"), bounce: true },
    );
    expect(del).toHaveSuccessfulTx({ to: item.address });
    expect(item.dnsresolve(makeDotSlice(), CAT_SITE).resolvedRecord).toEqual(null);
}

get fun `test item: dnsresolve category 0, delegation and missing record`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _res) = mintSubdomain(
        coll,
        user,
        "alice",
    ); // has a wallet record (setWalletToMinter)

    // category 0 -> full records dict
    expect(item.dnsresolve(makeDotSlice(), 0).resolvedRecord).toBeNotNull();
    // deeper name (bits > 8) -> forces next_resolver, which is unset -> null
    expect(
        item.dnsresolve(makeLeadingZero(makeDotSlice()), CAT_WALLET).resolvedRecord,
    ).toEqual(null);
    // a category with no record -> null
    expect(item.dnsresolve(makeDotSlice(), CAT_STORAGE).resolvedRecord).toEqual(null);
}

get fun `test transfer: rejects a masterchain new owner (wrong workchain)`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _res) = mintSubdomain(coll, user, "alice");

    val mcOwner = address.fromWorkchainAndHash(MASTERCHAIN, labelIndex("x"));
    val res = item.sendTransferOwnership(
        user.address,
        1,
        makeTransferData(mcOwner, user.address, ton("0.05")),
        { value: ton("1"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: item.address, exitCode: ERROR_WRONG_WORKCHAIN });
}

// ----------------------------------------------------------------- real-DnsItem compatibility

get fun `test lock: landing pin is a ChangeDnsRecord the real .ton DnsItem accepts`() {
    val (coll, parent, owner, _user) = deployLockedCollection();
    // LockCollection itself must NOT pin (it would race the in-flight NFT hand-off): the pin
    // fires when the parent lands (OwnershipAssigned), as a ChangeDnsRecord (0x4eb1f0f9).
    val landed = coll.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 2,
            oldOwnerAddress: owner.address,
            payload: emptyPayload(),
        }.toCell(),
        { value: ton("0.2"), bounce: false },
    );
    expect(
        landed.findTransaction<ChangeDnsRecord>({ from: coll.address, to: parent.address }),
    ).toBeNotNull();
}

get fun `test topup: Excesses is accepted silently by collection and item (no aborted tx)`() {
    val (coll, parent, _owner, user) = deployLockedCollection();
    // collection: the DnsItem routes its transfer change here as Excesses; must not throw
    val toColl = coll.sendAny(
        parent.address,
        Excesses { queryId: 7 }.toCell(),
        { value: ton("0.2"), bounce: true },
    );
    expect(toColl).toHaveSuccessfulTx({ to: coll.address });

    // item: a transfer's response excess; must not throw either
    val (item, _res) = mintSubdomain(coll, user, "alice");
    val toItem = item.sendAny(
        user.address,
        Excesses { queryId: 8 }.toCell(),
        { value: ton("0.1"), bounce: true },
    );
    expect(toItem).toHaveSuccessfulTx({ to: item.address });
}
