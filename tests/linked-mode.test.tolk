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

    val factory = SubdomainFactory.fromStorage({ pending: [] });
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

    val factory = SubdomainFactory.fromStorage({ pending: [] });
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

    // 0.5 TON exceeds deploy + gas margin, so the surplus is explicitly returned to the creator.
    expect(
        res.findTransaction<Excesses>({ from: factory.address, to: owner.address }),
    ).toBeNotNull();
}

get fun `test linked: a third party cannot deploy the owner's creator-bound address`() {
    val owner = newActor("bound-owner");
    val attacker = newActor("bound-attacker");
    val parent = newActor("bound-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
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
}

get fun `test linked: duplicate create returns deploy value to the creator`() {
    val owner = newActor("duplicate-owner");
    val parent = newActor("duplicate-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
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

get fun `test linked: immutable creator witness survives a parent-proven claim`() {
    val (coll, parent, owner, user) = deployLinkedCollection();
    expect(coll.getLinkedAdmin()).toEqual(owner.address);

    val direct = coll.sendTransferAdmin(
        owner.address,
        76,
        user.address,
        { value: ton("0.1"), bounce: true },
    );
    expect(direct).toHaveFailedTx({
        to: coll.address,
        exitCode: ERROR_LINKED_OWNER_PROOF_REQUIRED,
    });

    val moved = coll.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 77,
            oldOwnerAddress: user.address,
            payload: linkedActionPayload(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: MIN_PARENT_RETURN_VALUE, bounce: false },
    );
    expect(moved).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getAdmin()).toEqual(user.address);
    expect(coll.getLinkedAdmin()).toEqual(owner.address);
    expect(
        moved.findTransaction<TransferOwnership>({ from: coll.address, to: parent.address }),
    ).toBeNotNull();
}

get fun `test linked: factory rejects an underfunded Linked create`() {
    val owner = newActor("lowner3");
    val parent = newActor("lp3");

    val factory = SubdomainFactory.fromStorage({ pending: [] });
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
}

get fun `test linked: factory rejects one nanotON below the exact funding boundary`() {
    val owner = newActor("boundary-owner");
    val parent = newActor("boundary-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val res = factory.sendCreateLinkedCollection(
        owner.address,
        1,
        parent.address,
        owner.address,
        makeMeta(),
        { value: COLLECTION_DEPLOY_VALUE + FACTORY_GAS_MARGIN - 1, bounce: true },
    );
    expect(res).toHaveFailedTx({ to: factory.address, exitCode: ERROR_INSUFFICIENT_BALANCE });
}

get fun `test linked: factory accepts the exact deploy plus gas boundary`() {
    val owner = newActor("exact-owner");
    val parent = newActor("exact-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val res = factory.sendCreateLinkedCollection(
        owner.address,
        1,
        parent.address,
        owner.address,
        makeMeta(),
        { value: COLLECTION_DEPLOY_VALUE + FACTORY_GAS_MARGIN, bounce: true },
    );
    expect(res).toHaveSuccessfulTx({ to: factory.address });
    expect(
        testing.isDeployed(factory.getLinkedCollectionAddress(parent.address, owner.address)),
    ).toEqual(true);
    val collection = factory.getLinkedCollectionAddress(parent.address, owner.address);
    expect(testing.getAccountBalance(collection)).toBeGreater(
        testing.getAccountStorageFee(collection, 10 * 365 * 24 * 60 * 60)!,
    );
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
    val factory = SubdomainFactory.fromStorage({ pending: [] });
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
}

get fun `test linked: factory rejects a masterchain parent`() {
    val owner = newActor("mc-parent-owner");
    val mcParent = address.fromWorkchainAndHash(MASTERCHAIN, labelIndex("linked-mc-parent"));
    val factory = SubdomainFactory.fromStorage({ pending: [] });
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
}

get fun `test linked: factory rejects an invalid price grid`() {
    val owner = newActor("bad-grid-owner");
    val parent = newActor("bad-grid-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
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
        pRest: ton("0.6"), // non-monotonic: pRest exceeds p10
    };
    var badMeta = makeMeta();
    badMeta.priceConfig = badGrid.toCell();

    val res = factory.sendCreateLinkedCollection(
        owner.address,
        1,
        parent.address,
        owner.address,
        badMeta,
        { value: ton("0.5"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: factory.address, exitCode: ERROR_UNKNOWN_OP });
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

get fun `test linked: an accidental parent transfer is safely returned without changing mode`() {
    val (coll, parent, owner, _user) = deployLinkedCollection();
    expect(coll.getIsLinked()).toEqual(true);

    // No v3 action means safe return, never an implicit custody transition.
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

    expect(coll.getIsLinked()).toEqual(true);
    expect(
        landed.findTransaction<TransferOwnership>({ from: coll.address, to: parent.address }),
    ).toBeNotNull();

    val invalidInline = beginCell()
        .storeBool(false)
        .storeRef(
            LinkedParentAction { action: LINKED_ACTION_CLAIM }.toCell(),
        )
        .endCell()
        .beginParse();
    val inlineClaimant = newActor("linked-inline-claimant");
    val rejectedInline = coll.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 10,
            oldOwnerAddress: inlineClaimant.address,
            payload: invalidInline,
        }.toCell(),
        { value: ton("0.2"), bounce: false },
    );
    expect(rejectedInline).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getAdmin()).toEqual(owner.address);
    expect(
        rejectedInline.findTransaction<TransferOwnership>({
            from: coll.address,
            to: parent.address,
        }),
    ).toBeNotNull();
}

get fun `test linked: explicit Locked conversion commits even when the pin cannot be funded`() {
    val master = newActor("thin-master");
    val parent = newActor("thin-parent");
    val owner = newActor("thin-owner");
    val coll = SubdomainCollection.fromStorage({
        master: master.address,
        parentDomain: parent.address,
        isLinked: true,
        linkedAdmin: owner.address,
    });
    // Keep the setup deliberately thin so the best-effort resolver pin cannot use old balance.
    coll.deploy(master.address, { value: ton("0.001"), bounce: false });
    coll.sendAny(
        master.address,
        LockCollection {
            queryId: 1,
            parentDomain: parent.address,
            admin: owner.address,
            isLinked: true,
            meta: makeMeta().toCell(),
        }.toCell(),
        { value: ton("0.003"), bounce: false },
    );
    expect(coll.getIsLinked()).toEqual(true);

    // Explicit conversion is authoritative even when the best-effort pin action cannot be created.
    val landed = coll.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 2,
            oldOwnerAddress: owner.address,
            payload: linkedActionPayload(LINKED_ACTION_CONVERT_LOCKED),
        }.toCell(),
        { value: ton("0.001"), bounce: false },
    );
    expect(landed).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getIsLinked()).toEqual(false);
    expect(
        landed.findTransaction<ChangeDnsRecord>({ from: coll.address, to: parent.address }),
    ).toEqual(null);
}

get fun `test linked: cached admin cannot rescue the parent`() {
    val (coll, parent, owner, _user) = deployLinkedCollection();

    val rescue = coll.sendRescueNft(
        owner.address,
        1,
        parent.address,
        owner.address,
        { value: ton("0.2"), bounce: true },
    );
    expect(rescue).toHaveFailedTx({
        to: coll.address,
        exitCode: ERROR_RESCUE_PARENT_FORBIDDEN,
    });
    expect(
        rescue.findTransaction<TransferOwnership>({ from: coll.address, to: parent.address }),
    ).toEqual(null);
}

get fun `test linked: after upgrade to Locked the parent is rescue-protected again (anti-rug)`() {
    val (coll, parent, owner, _user) = deployLinkedCollection();

    // explicit Linked -> Locked conversion
    coll.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 1,
            oldOwnerAddress: owner.address,
            payload: linkedActionPayload(LINKED_ACTION_CONVERT_LOCKED),
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
    val (coll, parent, owner, _user) = deployLinkedCollection();
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
    expect(coll.getAdmin()).toEqual(owner.address);
    expect(coll.getParentReturn().pending).toEqual(false);
    expect(
        res.findTransaction<TransferOwnership>({ from: coll.address, to: parent.address }),
    ).toEqual(null);
}
