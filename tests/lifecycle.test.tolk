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

get fun `test lock: collection deploys locked; the parent .ton landing re-pins (no error)`() {
    val (coll, parent, owner, _user) = deployLockedCollection();

    // locked, admin = original owner, parent recorded
    expect(coll.getAdmin()).toEqual(owner.address);
    expect(coll.getParentDomain()).toEqual(parent.address);

    // the parent .ton landing on us (handed off by the factory) is accepted and re-pins next_resolver
    val landed = coll.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 2,
            oldOwnerAddress: owner.address,
            payload: emptyPayload(),
        }.toCell(),
        { value: ton("0.2"), bounce: false },
    );
    expect(landed).toHaveSuccessfulTx({ to: coll.address });
    expect(
        landed.findTransaction<ChangeDnsRecord>({ from: coll.address, to: parent.address }),
    ).toBeNotNull();
}

get fun `test lock: only the master (factory) can lock the collection`() {
    val masterT = newActor("m2");
    val parent = newActor("p2");
    val attacker = newActor("attacker");

    val coll = SubdomainCollection.fromStorage({
        master: masterT.address,
        parentDomain: parent.address,
        isLinked: false,
        linkedAdmin: masterT.address,
    });
    coll.deploy(masterT.address, { value: ton("0.05"), bounce: false });

    // a non-master cannot lock it
    val res = coll.sendAny(
        attacker.address,
        LockCollection {
            queryId: 1,
            parentDomain: parent.address,
            admin: attacker.address,
            isLinked: false,
            meta: makeMeta().toCell(),
        }.toCell(),
        { value: ton("1"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_NOT_FROM_MASTER });
    expect(coll.getAdmin()).toEqual(null);
}

get fun `test mint: deterministic item, owner = minter, wallet record set`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();

    val expectedAddr = coll.getNftAddressByIndex(labelIndex("alice"));
    val (item, _res) = mintSubdomain(coll, user, "alice");

    expect(item.address).toEqual(expectedAddr);
    expect(testing.isDeployed(item.address)).toEqual(true);

    val data = item.getNftData();
    expect(data.isInitialized).toEqual(true);
    expect(data.ownerAddress).toEqual(user.address);
    expect(data.collectionAddress).toEqual(coll.address);
    expect(data.index).toEqual(labelIndex("alice"));
    expect(item.getEditor()).toEqual(user.address);
}

get fun `test resolve: collection routes label to its item address`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _res) = mintSubdomain(coll, user, "alice");

    val resolved = coll.dnsresolve(makeLabelDomainSlice("alice"), 0);
    expect(resolved.resolvedPrefixLengthBits).toEqual(5 * BYTE_SIZE);
    expect(resolved.resolvedRecord).toBeNotNull();
    expect(parseNextResolverCell(resolved.resolvedRecord!)).toEqual(item.address);

    // "." (self) resolves with no record
    val dot = coll.dnsresolve(makeDotSlice(), 0);
    expect(dot.resolvedPrefixLengthBits).toEqual(BYTE_SIZE);
    expect(dot.resolvedRecord).toEqual(null);
}

get fun `test resolve: item returns its own wallet record`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _res) = mintSubdomain(coll, user, "alice");

    // TEP-81 regression: query with the LITERAL sha256("wallet") (what wallets/tonapi use), not the
    // CAT_WALLET keeps the default wallet record keyed per standard, not `.toBase256()`.
    val walletResolved = item.dnsresolve(
        makeDotSlice(),
        0xe8d44050873dba865aa7c170ab4cce64d90839a34dcfd6cf71d14e0205443b1b,
    );
    expect(walletResolved.resolvedPrefixLengthBits).toEqual(BYTE_SIZE);
    expect(walletResolved.resolvedRecord).toBeNotNull();
}

get fun `test transfer: subdomain NFT changes owner (TEP-62)`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _res) = mintSubdomain(coll, user, "alice");
    val buyer = newActor("buyer");

    val transferRes = item.sendTransferOwnership(
        user.address,
        9,
        makeTransferData(buyer.address, user.address, ton("0.05")),
        { value: ton("1"), bounce: true },
    );
    expect(transferRes).toHaveSuccessfulTx({ to: item.address });
    expect(item.getEditor()).toEqual(buyer.address);

    // the old owner can no longer transfer
    val rogue = item.sendTransferOwnership(
        user.address,
        10,
        makeTransferData(user.address, user.address, ton("0.05")),
        { value: ton("1"), bounce: true },
    );
    expect(rogue).toHaveFailedTx({ to: item.address, exitCode: ERROR_NOT_OWNER });
}

get fun `test records: owner edits its own dns record`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val (item, _res) = mintSubdomain(coll, user, "alice");

    // set a site record (non-owner rejected, owner ok)
    val stranger = newActor("stranger");
    val recordVal = beginCell()
        .storeRef(beginCell().storeUint(0xad01, 16).endCell())
        .endCell()
        .beginParse();

    val badEdit = item.sendChangeDnsRecord(
        stranger.address,
        1,
        CAT_SITE,
        recordVal,
        { value: ton("1"), bounce: true },
    );
    expect(badEdit).toHaveFailedTx({ to: item.address, exitCode: ERROR_NOT_OWNER });

    val goodEdit = item.sendChangeDnsRecord(
        user.address,
        1,
        CAT_SITE,
        recordVal,
        { value: ton("1"), bounce: true },
    );
    expect(goodEdit).toHaveSuccessfulTx({ to: item.address });
}
