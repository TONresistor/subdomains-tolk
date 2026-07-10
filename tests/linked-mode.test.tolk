// Linked (self-custody) mode: the owner keeps their parent .ton and only points its next_resolver
// at the collection. The collection mints + resolves but owns nothing, so every parent-custody op is
// gated off. A Linked collection can later be upgraded to Locked by transferring the .ton in.
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
import "@wrappers/SubdomainFactory.gen"
import "@wrappers/SubdomainItem.gen"
import "test-utils"

// ============================ address-space separation (security) ============================

get fun `test linked: Locked and Linked addresses are distinct (no hijack overlap)`() {
    val deployer = newActor("ld");
    val parent = newActor("lparent");
    val attacker = newActor("lattacker");

    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(deployer.address, { value: ton("1"), bounce: false });

    // The same parent maps to two different deterministic addresses by mode. This is the boundary
    // that stops Linked from pre-occupying a born-Locked handoff. Linked is also creator-bound, so
    // another wallet cannot pre-occupy the real owner's immutable configuration either.
    val lockedAddr = factory.getCollectionAddress(parent.address);
    val linkedAddr = factory.getLinkedCollectionAddress(parent.address, deployer.address);
    val attackerAddr = factory.getLinkedCollectionAddress(parent.address, attacker.address);
    expect(lockedAddr == linkedAddr).toEqual(false);
    expect(linkedAddr == attackerAddr).toEqual(false);
}

// ============================ factory CreateLinkedCollection ============================

get fun `test linked: factory deploys a Linked collection with no .ton handoff`() {
    val owner = newActor("lowner");
    val parent = newActor("lp2"); // the owner's .ton, which they KEEP

    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val expected = factory.getLinkedCollectionAddress(parent.address, owner.address);
    val res = factory.sendCreateLinkedCollection(
        owner.address,
        1,
        parent.address,
        owner.address,
        makeMeta(),
        { value: ton("0.5"), bounce: true },
    );
    expect(res).toHaveSuccessfulTx({ to: factory.address });

    // a collection deployed at the LINKED address, self-custody, admin = the sender
    val deployTx = res.findTransaction({ from: factory.address, deploy: true });
    expect(deployTx).toBeNotNull();
    expect(deployTx!.getAccountAddress()).toEqual(expected);
    val coll = SubdomainCollection.fromAddress(expected);
    expect(coll.isLocked()).toEqual(true);    // initialized
    expect(coll.getIsLinked()).toEqual(true); // but self-custody
    expect(coll.getAdmin()).toEqual(owner.address);

    // crucially: the factory NEVER transfers a .ton anywhere (the owner kept it)
    expect(
        res.findTransaction<TransferOwnership>({ from: factory.address, to: parent.address }),
    ).toEqual(null);
    expect(factory.getDeployedCount()).toEqual(1);

    // 0.5 TON exceeds deploy + gas margin, so the surplus is explicitly returned to the creator.
    expect(
        res.findTransaction<Excesses>({ from: factory.address, to: owner.address }),
    ).toBeNotNull();
}

get fun `test linked: a third party cannot deploy the owner's creator-bound address`() {
    val owner = newActor("bound-owner");
    val attacker = newActor("bound-attacker");
    val parent = newActor("bound-parent");
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val ownerAddress = factory.getLinkedCollectionAddress(parent.address, owner.address);
    val res = factory.sendCreateLinkedCollection(
        attacker.address,
        1,
        parent.address,
        owner.address, // attempted impersonation / immutable-config pre-occupation
        makeMeta(),
        { value: ton("0.5"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: factory.address, exitCode: ERROR_NOT_ADMIN });
    expect(testing.isDeployed(ownerAddress)).toEqual(false);
    expect(factory.getDeployedCount()).toEqual(0);
}

get fun `test linked: duplicate create returns deploy value to the creator`() {
    val owner = newActor("duplicate-owner");
    val parent = newActor("duplicate-parent");
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    factory.sendCreateLinkedCollection(
        owner.address,
        1,
        parent.address,
        owner.address,
        makeMeta(),
        { value: ton("0.5"), bounce: true },
    );
    val linked = factory.getLinkedCollectionAddress(parent.address, owner.address);

    val duplicate = factory.sendCreateLinkedCollection(
        owner.address,
        2,
        parent.address,
        owner.address,
        makeMeta(),
        { value: ton("0.5"), bounce: true },
    );
    expect(duplicate).toHaveSuccessfulTx({ to: linked });
    expect(
        duplicate.findTransaction<Excesses>({ from: linked, to: owner.address }),
    ).toBeNotNull();
    expect(SubdomainCollection.fromAddress(linked).getAdmin()).toEqual(owner.address);
}

get fun `test linked: immutable creator witness survives TransferAdmin`() {
    val (coll, _parent, owner, user) = deployLinkedCollection();
    expect(coll.getLinkedAdmin()).toEqual(owner.address);

    val moved = coll.sendTransferAdmin(
        owner.address,
        77,
        user.address,
        { value: ton("0.1"), bounce: true },
    );
    expect(moved).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getAdmin()).toEqual(user.address);
    expect(coll.getLinkedAdmin()).toEqual(owner.address);
    expect(
        moved.findTransaction<AdminAssigned>({ from: coll.address, to: user.address }),
    ).toBeNotNull();
}

get fun `test linked: factory rejects an underfunded Linked create`() {
    val owner = newActor("lowner3");
    val parent = newActor("lp3");

    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val res = factory.sendCreateLinkedCollection(
        owner.address,
        1,
        parent.address,
        owner.address,
        makeMeta(),
        { value: ton("0.1"), bounce: true }, // < COLLECTION_DEPLOY_VALUE + margin
    );
    expect(res).toHaveFailedTx({ to: factory.address, exitCode: ERROR_INSUFFICIENT_BALANCE });
    expect(factory.getDeployedCount()).toEqual(0);
}

get fun `test linked: factory rejects one nanotON below the exact funding boundary`() {
    val owner = newActor("boundary-owner");
    val parent = newActor("boundary-parent");
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val res = factory.sendCreateLinkedCollection(
        owner.address,
        1,
        parent.address,
        owner.address,
        makeMeta(),
        { value: ton("0.259999999"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: factory.address, exitCode: ERROR_INSUFFICIENT_BALANCE });
    expect(factory.getDeployedCount()).toEqual(0);
}

get fun `test linked: factory accepts the exact deploy plus gas boundary`() {
    val owner = newActor("exact-owner");
    val parent = newActor("exact-parent");
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val res = factory.sendCreateLinkedCollection(
        owner.address,
        1,
        parent.address,
        owner.address,
        makeMeta(),
        { value: ton("0.26"), bounce: true },
    );
    expect(res).toHaveSuccessfulTx({ to: factory.address });
    expect(
        testing.isDeployed(factory.getLinkedCollectionAddress(parent.address, owner.address)),
    ).toEqual(true);
    // The exact create has no immediate surplus. CollectionReady later carries FACTORY_READY_VALUE
    // back, and the factory forwards that callback remainder instead of retaining it.
    val callbackRefund = res.findTransaction<Excesses>({
        from: factory.address,
        to: owner.address,
    });
    expect(callbackRefund).toBeNotNull();
    val callbackRefundTx = callbackRefund!;
    expect(callbackRefundTx.loadBody<Excesses>().queryId).toEqual(1);
    val callbackRefundInfo = callbackRefundTx.loadInMsg<Excesses>().info;
    match (callbackRefundInfo) {
        TlbInternalMessage => {
            expect(callbackRefundInfo.value.grams).toBeGreater(0);
            expect(callbackRefundInfo.value.grams).toBeLessOrEqual(FACTORY_READY_VALUE);
        }
        TlbExternalInMessageInfo => throw 0,
        TlbExternalOutMessageInfo => throw 0,
    }
}

get fun `test linked: factory rejects a masterchain admin before sender binding`() {
    val owner = newActor("mc-admin-owner");
    val parent = newActor("mc-admin-parent");
    val mcAdmin = address.fromWorkchainAndHash(MASTERCHAIN, labelIndex("linked-mc-admin"));
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val res = factory.sendCreateLinkedCollection(
        owner.address,
        1,
        parent.address,
        mcAdmin,
        makeMeta(),
        { value: ton("0.5"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: factory.address, exitCode: ERROR_WRONG_WORKCHAIN });
    expect(factory.getDeployedCount()).toEqual(0);
}

get fun `test linked: factory rejects a masterchain parent`() {
    val owner = newActor("mc-parent-owner");
    val mcParent = address.fromWorkchainAndHash(MASTERCHAIN, labelIndex("linked-mc-parent"));
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val res = factory.sendCreateLinkedCollection(
        owner.address,
        1,
        mcParent,
        owner.address,
        makeMeta(),
        { value: ton("0.5"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: factory.address, exitCode: ERROR_WRONG_WORKCHAIN });
    expect(factory.getDeployedCount()).toEqual(0);
}

get fun `test linked: factory rejects an invalid price grid`() {
    val owner = newActor("bad-grid-owner");
    val parent = newActor("bad-grid-parent");
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0, pending: [], deployed: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });
    val badGrid: PriceConfig = {
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
        pRest: ton("0.01"), // below MIN_NAME_PRICE
    };
    val badMeta: CollectionMeta = {
        priceConfig: badGrid.toCell(),
        collectionContent: beginCell().endCell(),
        itemContentBaseUri: beginCell().endCell(),
    };

    val res = factory.sendCreateLinkedCollection(
        owner.address,
        1,
        parent.address,
        owner.address,
        badMeta,
        { value: ton("0.5"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: factory.address, exitCode: ERROR_UNKNOWN_OP });
    expect(factory.getDeployedCount()).toEqual(0);
}

get fun `test linked: skeleton rejects an admin different from its creator binding`() {
    val master = newActor("bound-master");
    val parent = newActor("bound-lock-parent");
    val owner = newActor("bound-lock-owner");
    val attacker = newActor("bound-lock-attacker");
    val coll = SubdomainCollection.fromStorage({
        master: master.address,
        parentDomain: parent.address,
        isLinked: true,
        linkedAdmin: owner.address,
    });
    coll.deploy(master.address, { value: ton("0.05"), bounce: false });
    expect(coll.getLinkedAdmin()).toEqual(owner.address);

    val res = coll.sendAny(
        master.address,
        LockCollection {
            queryId: 1,
            parentDomain: parent.address,
            admin: attacker.address,
            isLinked: true,
            meta: makeMeta().toCell(),
        }.toCell(),
        { value: ton("0.5"), bounce: false },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_NOT_ADMIN });
    expect(coll.getAdmin()).toEqual(null);
}

// ============================ minting works identically ============================

get fun `test linked: minting works and never heartbeats the parent`() {
    testing.setNow(1700000000);
    val (coll, parent, _owner, user) = deployLinkedCollection();

    // mint succeeds (item deployed)
    val (item, _res) = mintSubdomain(coll, user, "alice");
    expect(testing.isDeployed(item.address)).toEqual(true);

    // even past the throttle window, a Linked mint sends NO op-0 heartbeat to the parent
    // (the collection isn't the .ton owner; the owner renews their own domain).
    testing.setNow(1700000000 + 86400 + 10);
    val (_item2, res2) = mintSubdomain(coll, user, "bobby");
    expect(res2.findTransaction({ from: coll.address, to: parent.address })).toEqual(null);
}

// ============================ custody ops are gated off ============================

get fun `test linked: fill-up parent is rejected (no custody)`() {
    val (coll, _parent, owner, _user) = deployLinkedCollection();
    val res = coll.sendFillUpParent(owner.address, 1, { value: ton("1"), bounce: true });
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LINKED_NO_CUSTODY });
}

get fun `test linked: enforce-resolver is rejected (no custody)`() {
    val (coll, _parent, owner, _user) = deployLinkedCollection();
    val res = coll.sendEnforceResolver(owner.address, 1, { value: ton("0.2"), bounce: true });
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LINKED_NO_CUSTODY });
}

get fun `test linked: proxy-edit parent record is rejected (no custody)`() {
    val (coll, _parent, owner, _user) = deployLinkedCollection();
    val res = coll.sendProxyEditParentRecord(
        owner.address, // admin
        1,
        CAT_WALLET,
        emptyPayload(),
        { value: ton("0.2"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LINKED_NO_CUSTODY });
}

// ============================ Linked -> Locked upgrade ============================

get fun `test linked: transferring the parent .ton in upgrades Linked -> Locked`() {
    val (coll, parent, owner, _user) = deployLinkedCollection();
    expect(coll.getIsLinked()).toEqual(true);

    // the owner transfers their parent .ton INTO the collection (the upgrade trigger)
    val landed = coll.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 9,
            oldOwnerAddress: owner.address,
            payload: emptyPayload(),
        }.toCell(),
        { value: ton("0.2"), bounce: false },
    );
    expect(landed).toHaveSuccessfulTx({ to: coll.address });

    // custody taken: the flag flipped, and the collection pinned next_resolver on the parent
    expect(coll.getIsLinked()).toEqual(false);
    expect(
        landed.findTransaction<ChangeDnsRecord>({ from: coll.address, to: parent.address }),
    ).toBeNotNull();

    // custody ops now work (it is a normal Locked collection from here on)
    val fill = coll.sendFillUpParent(owner.address, 10, { value: ton("1"), bounce: true });
    expect(fill).toHaveSuccessfulTx({ to: coll.address });
}

get fun `test linked: custody commits even when the landing cannot fund the resolver pin`() {
    val master = newActor("thin-master");
    val parent = newActor("thin-parent");
    val owner = newActor("thin-owner");
    val coll = SubdomainCollection.fromStorage({
        master: master.address,
        parentDomain: parent.address,
        isLinked: true,
        linkedAdmin: owner.address,
    });
    // Enough to emit the mandatory factory-ready acknowledgement, still below the 0.05 TON pin.
    coll.deploy(master.address, { value: ton("0.02"), bounce: false });
    coll.sendAny(
        master.address,
        LockCollection {
            queryId: 1,
            parentDomain: parent.address,
            admin: owner.address,
            isLinked: true,
            meta: makeMeta().toCell(),
        }.toCell(),
        { value: ton("0.02"), bounce: false },
    );
    expect(coll.getIsLinked()).toEqual(true);

    // The collection remains below the 0.05 TON pin value. IGNORE_ERRORS makes custody the
    // authoritative transition: the NFT remains locked and EnforceResolver can repair the pin later.
    val landed = coll.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 2,
            oldOwnerAddress: owner.address,
            payload: emptyPayload(),
        }.toCell(),
        { value: ton("0.001"), bounce: false },
    );
    expect(landed).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getIsLinked()).toEqual(false);
    expect(
        landed.findTransaction<ChangeDnsRecord>({ from: coll.address, to: parent.address }),
    ).toEqual(null);
}

get fun `test linked: a stray parent .ton can be rescued in Linked mode (no strand)`() {
    val (coll, parent, owner, _user) = deployLinkedCollection();

    // If the parent .ton ever ends up held by a Linked collection, the admin MUST be able to return
    // it — otherwise it is permanently stranded. In Linked mode rescuing the parent is allowed.
    val rescue = coll.sendRescueNft(
        owner.address,  // admin
        1,
        parent.address, // the parent .ton itself
        owner.address,  // send it back to the owner
        { value: ton("0.2"), bounce: true },
    );
    expect(rescue).toHaveSuccessfulTx({ to: coll.address });
    expect(
        rescue.findTransaction<TransferOwnership>({ from: coll.address, to: parent.address }),
    ).toBeNotNull();
}

get fun `test linked: after upgrade to Locked the parent is rescue-protected again (anti-rug)`() {
    val (coll, parent, owner, _user) = deployLinkedCollection();

    // upgrade Linked -> Locked
    coll.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 1,
            oldOwnerAddress: owner.address,
            payload: emptyPayload(),
        }.toCell(),
        { value: ton("0.2"), bounce: false },
    );
    expect(coll.getIsLinked()).toEqual(false);

    // now custodial: the anti-rug guarantee re-applies, the parent can no longer be rescued
    val rescue = coll.sendRescueNft(
        owner.address,
        2,
        parent.address,
        owner.address,
        { value: ton("0.2"), bounce: true },
    );
    expect(rescue).toHaveFailedTx({ to: coll.address, exitCode: ERROR_RESCUE_PARENT_FORBIDDEN });
}

get fun `test linked: a stray non-parent NFT never force-locks a Linked collection`() {
    val (coll, _parent, _owner, _user) = deployLinkedCollection();
    val stranger = newActor("stranger");

    // an OwnershipAssigned from anyone other than the parent .ton must NOT take custody
    val res = coll.sendAny(
        stranger.address,
        OwnershipAssigned {
            queryId: 1,
            oldOwnerAddress: stranger.address,
            payload: emptyPayload(),
        }.toCell(),
        { value: ton("0.2"), bounce: false },
    );
    expect(res).toHaveSuccessfulTx({ to: coll.address }); // absorbed, no throw
    expect(coll.getIsLinked()).toEqual(true);             // still self-custody
}
