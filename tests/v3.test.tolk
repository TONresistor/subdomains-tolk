import "@acton/build"
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
import "test-utils"

fun zeroPriceConfig(): PriceConfig {
    return {
        minChars: 4,
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

fun v3RichBounceBody(originalBody: cell, originalValue: coins): cell {
    val info: RichBounceOriginalMsgInfo = {
        valueCoins: originalValue,
        valueExtra: [],
        createdLt: 0,
        createdAt: 0,
    };
    return RichBounceBody {
        originalBody,
        originalInfo: info.toCell(),
        bouncedByPhase: 1,
        exitCode: ERROR_UNKNOWN_OP,
        computePhase: null,
    }.toCell();
}

fun v3MessageValue(info: TlbCommonMessageInfo): coins {
    match (info) {
        TlbInternalMessage => return info.value.grams,
        TlbExternalInMessageInfo => throw 0,
        TlbExternalOutMessageInfo => throw 0,
    }
}

fun deployCollectionWithPolicyAndMeta(
    policy: CollectionPolicyState,
    meta: CollectionMeta,
    value: coins = ton("1"),
): (SubdomainCollection, Treasury, Treasury, Treasury) {
    val master = newActor("v3-policy-master");
    val parent = newActor("v3-policy-parent");
    val owner = newActor("v3-policy-owner");
    val user = newActor("v3-policy-user");
    val storage: CollectionStorage = {
        master: master.address,
        parentDomain: parent.address,
        admin: owner.address,
        origin: CollectionOrigin {
            linkedAdmin: master.address,
            isLinkedAtDeployment: false,
            lastFactoryHandoff: null,
        }.toCell(),
        isLinked: false,
        lastParentFillUp: blockchain.now(),
        meta: meta.toCell(),
        names: CollectionNames {
            reserved: [],
            minted: [],
            mintedCount: 0,
        }.toCell(),
        policy: policy.toCell(),
    };
    val stateInit: ContractState = { code: build("SubdomainCollection"), data: storage.toCell() };
    val collection: SubdomainCollection = {
        address: AutoDeployAddress { stateInit }.calculateAddress(),
        stateInit,
    };
    collection.deploy(master.address, { value, bounce: false });
    return (collection, parent, owner, user);
}

get fun `test v3: zero protocol pricing mints with execution funding only`() {
    val policy: CollectionPolicyState = {
        accessMode: ACCESS_PUBLIC,
        withdrawableRevenue: 0,
        allowlist: [],
        pendingMints: [],
        parentGeneration: 0,
        pendingParentReturn: null,
    };
    var meta = makeMeta();
    meta.priceConfig = zeroPriceConfig().toCell();
    val (collection, _parent, _owner, user) = deployCollectionWithPolicyAndMeta(policy, meta);

    val quote = collection.getMintQuote(user.address, 5);
    expect(quote.allowed).toEqual(true);
    expect(quote.effectivePrice).toEqual(0);
    expect(quote.requiredValue).toEqual(ITEM_DEPLOY_COST + MINT_FEE_BUFFER);

    val minted = collection.sendRegisterSubdomain(
        user.address,
        2,
        labelSlice("alice"),
        true,
        testOnchainMetadata(),
        { value: ITEM_DEPLOY_COST + MINT_FEE_BUFFER, bounce: true },
    );
    expect(minted).toHaveSuccessfulTx({ from: collection.address, deploy: true });
    expect(collection.getMintedCount()).toEqual(1);
    expect(collection.getWithdrawableRevenue()).toEqual(0);
}

get fun `test v3: allowlist controls access without changing prices`() {
    val (collection, _parent, owner, user) = deployLockedCollection();
    val outsider = newActor("v3-allowlist-outsider");

    collection.sendSetAccessMode(
        owner.address,
        1,
        ACCESS_ALLOWLIST,
        { value: ton("0.05"), bounce: true },
    );
    collection.sendSetAccessMode(
        owner.address,
        10,
        ACCESS_ALLOWLIST,
        { value: ton("0.05"), bounce: true },
    );
    val denied = collection.sendRegisterSubdomain(
        outsider.address,
        2,
        labelSlice("denied"),
        true,
        testOnchainMetadata(),
        { value: ton("10"), bounce: true },
    );
    expect(denied).toHaveFailedTx({ to: collection.address, exitCode: ERROR_MINT_NOT_ALLOWED });

    collection.sendSetAllowlistEntry(
        owner.address,
        3,
        user.address,
        true,
        { value: ton("0.05"), bounce: true },
    );
    expect(collection.getIsAllowlisted(user.address)).toEqual(true);
    collection.sendSetAllowlistEntry(
        owner.address,
        30,
        user.address,
        true,
        { value: ton("0.05"), bounce: true },
    );
    expect(collection.getMintQuote(user.address, 5).effectivePrice).toEqual(ton("5"));

    val first = collection.sendRegisterSubdomain(
        user.address,
        4,
        labelSlice("alice"),
        true,
        testOnchainMetadata(),
        { value: ton("5.1"), bounce: true },
    );
    expect(first).toHaveSuccessfulTx({ from: collection.address, deploy: true });
    expect(collection.getWithdrawableRevenue()).toEqual(ton("5"));

    val second = collection.sendRegisterSubdomain(
        user.address,
        5,
        labelSlice("bobby"),
        true,
        testOnchainMetadata(),
        { value: ton("5.1"), bounce: true },
    );
    expect(second).toHaveSuccessfulTx({ from: collection.address, deploy: true });

    collection.sendSetAllowlistEntry(
        owner.address,
        6,
        user.address,
        false,
        { value: ton("0.05"), bounce: true },
    );
    expect(collection.getMintQuote(user.address, 5).allowed).toEqual(false);
    collection.sendSetAllowlistEntry(
        owner.address,
        7,
        user.address,
        false,
        { value: ton("0.05"), bounce: true },
    );
}

get fun `test v3: admin-only policy blocks users but not the admin`() {
    val (collection, _parent, owner, user) = deployLockedCollection();
    collection.sendSetAccessMode(
        owner.address,
        1,
        ACCESS_ADMIN_ONLY,
        { value: ton("0.05"), bounce: true },
    );
    expect(collection.getMintQuote(user.address, 5).allowed).toEqual(false);
    expect(collection.getMintQuote(owner.address, 5).allowed).toEqual(true);

    val adminMint = collection.sendRegisterSubdomain(
        owner.address,
        2,
        labelSlice("owner"),
        true,
        testOnchainMetadata(),
        { value: ton("5.1"), bounce: true },
    );
    expect(adminMint).toHaveSuccessfulTx({ from: collection.address, deploy: true });
}

get fun `test v3: lost ItemReady is finalized through authenticated static data`() {
    val (collection, _parent, _owner, user) = deployLockedCollection();
    val index = labelIndex("alice");
    val request = createMessage({
        bounce: true,
        dest: collection.address,
        value: ton("6"),
        body: RegisterSubdomain {
            queryId: 88,
            label: labelSlice("alice").toCell(),
            setWalletToMinter: true,
            content: testOnchainMetadata(),
        },
    });
    val registerStep = testing.processSingleTraceStep(user.address, request);
    val deploy = registerStep.outMessages.at<SubdomainInit>(0);
    testing.processSingleTraceStep(collection.address, { messageCell: deploy.toCell() });
    expect(collection.getIsMintPending(index)).toEqual(true);
    expect(collection.getMintedCount()).toEqual(0);

    val confirmation = collection.sendConfirmMint(
        user.address,
        89,
        index,
        { value: MIN_CONFIRM_MINT_VALUE, bounce: true },
    );
    expect(confirmation).toHaveSuccessfulTx({ to: collection.address });
    expect(collection.getIsMintPending(index)).toEqual(false);
    expect(collection.getMintedCount()).toEqual(1);
    expect(collection.getWithdrawableRevenue()).toEqual(ton("5"));
}

get fun `test v3: parent proof claims Linked admin and authenticated Excesses finalizes return`() {
    val (collection, parent, _seller, _user) = deployLinkedCollection();
    val buyer = newActor("v3-linked-buyer");

    val claim = collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 700,
            oldOwnerAddress: buyer.address,
            payload: linkedActionPayload(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: MIN_PARENT_RETURN_VALUE + ton("0.04"), bounce: false },
    );
    expect(claim).toHaveSuccessfulTx({ to: collection.address });
    expect(collection.getAdmin()).toEqual(buyer.address);
    expect(collection.getIsLinked()).toEqual(true);
    val pending = collection.getParentReturn();
    expect(pending.pending).toEqual(true);
    expect(pending.recipient).toEqual(buyer.address);
    expect(
        claim.findTransaction<TransferOwnership>({ from: collection.address, to: parent.address }),
    ).toBeNotNull();

    val acknowledgement = collection.sendAny(
        parent.address,
        Excesses { queryId: pending.returnQueryId }.toCell(),
        { value: ton("0.08"), bounce: false },
    );
    expect(acknowledgement).toHaveSuccessfulTx({ to: collection.address });
    expect(collection.getParentReturn().pending).toEqual(false);
    expect(
        acknowledgement.findTransaction<Excesses>({
            from: collection.address,
            to: buyer.address,
        }),
    ).toBeNotNull();
}

get fun `test v3: a new parent proof clears a stale return receipt across owners`() {
    val (collection, parent, seller, _user) = deployLinkedCollection();
    val buyer = newActor("v3-linked-receipt-buyer");

    collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 750,
            oldOwnerAddress: seller.address,
            payload: linkedActionPayload(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: MIN_PARENT_RETURN_VALUE, bounce: false },
    );
    expect(collection.getParentReturn().pending).toEqual(true);

    val converted = collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 751,
            oldOwnerAddress: buyer.address,
            payload: linkedActionPayload(LINKED_ACTION_CONVERT_LOCKED),
        }.toCell(),
        { value: MIN_PARENT_RETURN_VALUE, bounce: false },
    );
    expect(converted).toHaveSuccessfulTx({ to: collection.address });
    expect(collection.getAdmin()).toEqual(buyer.address);
    expect(collection.getIsLinked()).toEqual(false);
    expect(collection.getParentReturn().pending).toEqual(false);
}

get fun `test v3: unknown Linked action safe-returns without changing authority`() {
    val (collection, parent, owner, _user) = deployLinkedCollection();
    val claimant = newActor("v3-invalid-action-claimant");

    val unknown = collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 760,
            oldOwnerAddress: claimant.address,
            payload: linkedActionPayload(255),
        }.toCell(),
        { value: MIN_PARENT_RETURN_VALUE, bounce: false },
    );
    expect(unknown).toHaveSuccessfulTx({ to: collection.address });
    expect(collection.getAdmin()).toEqual(owner.address);
    expect(collection.getParentReturn().recipient).toEqual(claimant.address);
}

get fun `test v3: underfunded parent return stays permissionlessly retryable`() {
    val (collection, parent, owner, user) = deployLinkedCollection();
    val underfunded = collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 800,
            oldOwnerAddress: owner.address,
            payload: linkedActionPayload(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: ton("0.001"), bounce: false },
    );
    val pending = collection.getParentReturn();
    expect(pending.pending).toEqual(true);
    expect(pending.inFlight).toEqual(false);
    expect(
        underfunded.findTransaction<TransferOwnership>({
            from: collection.address,
            to: parent.address,
        }),
    ).toEqual(null);

    val low = collection.sendRetryParentReturn(
        user.address,
        801,
        { value: MIN_PARENT_RETURN_VALUE - 1, bounce: true },
    );
    expect(low).toHaveFailedTx({ to: collection.address, exitCode: ERROR_INSUFFICIENT_BALANCE });

    val retry = collection.sendRetryParentReturn(
        user.address,
        802,
        { value: MIN_PARENT_RETURN_VALUE, bounce: true },
    );
    expect(
        retry.findTransaction<TransferOwnership>({ from: collection.address, to: parent.address }),
    ).toBeNotNull();
    expect(collection.getParentReturn().inFlight).toEqual(true);
    val duplicate = collection.sendRetryParentReturn(
        user.address,
        803,
        { value: MIN_PARENT_RETURN_VALUE, bounce: true },
    );
    expect(duplicate).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_PARENT_TRANSFER_IN_FLIGHT,
    });
}

get fun `test v3: Linked claim requires parent proof and withdraws revenue`() {
    val (collection, parent, seller, user) = deployLinkedCollection();
    mintSubdomain(collection, user, "alice", ton("6"));
    expect(collection.getWithdrawableRevenue()).toEqual(ton("5"));

    val direct = collection.sendWithdrawFees(
        seller.address,
        900,
        ton("1"),
        { value: ton("0.05"), bounce: true },
    );
    expect(direct).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_LINKED_OWNER_PROOF_REQUIRED,
    });

    val claimant = newActor("v3-revenue-claimant");
    val claim = collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 901,
            oldOwnerAddress: claimant.address,
            payload: linkedActionPayload(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: MIN_PARENT_RETURN_VALUE, bounce: false },
    );
    expect(claim).toHaveSuccessfulTx({ from: collection.address, to: claimant.address });
    expect(collection.getAdmin()).toEqual(claimant.address);
    expect(collection.getWithdrawableRevenue()).toEqual(0);
    expect(collection.getParentReturn().recipient).toEqual(claimant.address);
}

get fun `test v3: item readiness authenticates sender and pending receipt`() {
    val (collection, _parent, _owner, user) = deployLockedCollection();
    val attacker = newActor("v3-ready-attacker");
    val index = labelIndex("alice");
    val forged = collection.sendItemReady(
        attacker.address,
        1,
        index,
        user.address,
        { value: ton("0.01"), bounce: true },
    );
    expect(forged).toHaveFailedTx({ to: collection.address, exitCode: ERROR_NOT_FROM_COLLECTION });
    expect(collection.getMintedCount()).toEqual(0);

    val request = createMessage({
        bounce: true,
        dest: collection.address,
        value: ton("6"),
        body: RegisterSubdomain {
            queryId: 10,
            label: labelSlice("alice").toCell(),
            setWalletToMinter: true,
            content: testOnchainMetadata(),
        },
    });
    testing.processSingleTraceStep(user.address, request);
    val itemAddress = collection.getNftAddressByIndex(index);
    val wrongReceipt = collection.sendItemReady(
        itemAddress,
        11,
        index,
        user.address,
        { value: ITEM_READY_VALUE, bounce: false },
    );
    expect(wrongReceipt).toHaveSuccessfulTx({ to: collection.address });
    expect(collection.getIsMintPending(index)).toEqual(true);
    expect(collection.getMintedCount()).toEqual(0);

    val ready = collection.sendItemReady(
        itemAddress,
        10,
        index,
        user.address,
        { value: ITEM_READY_VALUE, bounce: false },
    );
    expect(ready).toHaveSuccessfulTx({ to: collection.address });
    expect(collection.getIsMintPending(index)).toEqual(false);
    expect(collection.getMintedCount()).toEqual(1);

    val duplicate = collection.sendItemReady(
        itemAddress,
        10,
        index,
        user.address,
        { value: ITEM_READY_VALUE, bounce: false },
    );
    expect(duplicate).toHaveSuccessfulTx({ to: collection.address });
    expect(collection.getMintedCount()).toEqual(1);
}

get fun `test v3: policy administration validates mode and owner`() {
    val (collection, _parent, owner, user) = deployLockedCollection();
    val invalidMode = collection.sendSetAccessMode(
        owner.address,
        1,
        3,
        { value: ton("0.05"), bounce: true },
    );
    expect(invalidMode).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_INVALID_ACCESS_MODE,
    });

    val unauthorized = collection.sendSetAllowlistEntry(
        user.address,
        2,
        user.address,
        true,
        { value: ton("0.05"), bounce: true },
    );
    expect(unauthorized).toHaveFailedTx({ to: collection.address, exitCode: ERROR_NOT_ADMIN });
}

get fun `test v3: pending label cannot be bypassed`() {
    val (collection, _parent, _owner, user) = deployLockedCollection();
    val pendingRequest = createMessage({
        bounce: true,
        dest: collection.address,
        value: ton("6"),
        body: RegisterSubdomain {
            queryId: 3,
            label: labelSlice("alice").toCell(),
            setWalletToMinter: true,
            content: testOnchainMetadata(),
        },
    });
    testing.processSingleTraceStep(user.address, pendingRequest);
    val duplicate = collection.sendRegisterSubdomain(
        user.address,
        4,
        labelSlice("alice"),
        true,
        testOnchainMetadata(),
        { value: ton("6"), bounce: true },
    );
    expect(duplicate).toHaveFailedTx({ to: collection.address, exitCode: ERROR_LABEL_TAKEN });
}

get fun `test v3: static-data recovery authenticates sender and collection`() {
    val (collection, _parent, _owner, user) = deployLockedCollection();
    val attacker = newActor("v3-static-attacker");
    val index = labelIndex("alice");
    val request = createMessage({
        bounce: true,
        dest: collection.address,
        value: ton("6"),
        body: RegisterSubdomain {
            queryId: 10,
            label: labelSlice("alice").toCell(),
            setWalletToMinter: true,
            content: testOnchainMetadata(),
        },
    });
    testing.processSingleTraceStep(user.address, request);

    val forgedSender = collection.sendReportStaticData(
        attacker.address,
        11,
        index,
        collection.address,
        { value: ton("0.01"), bounce: true },
    );
    expect(forgedSender).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    val itemAddress = collection.getNftAddressByIndex(index);
    val wrongCollection = collection.sendReportStaticData(
        itemAddress,
        12,
        index,
        attacker.address,
        { value: ton("0.01"), bounce: true },
    );
    expect(wrongCollection).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });
    expect(collection.getIsMintPending(index)).toEqual(true);

    val noPendingIndex = labelIndex("absent");
    val noPending = collection.sendReportStaticData(
        collection.getNftAddressByIndex(noPendingIndex),
        13,
        noPendingIndex,
        collection.address,
        { value: ton("0.01"), bounce: true },
    );
    expect(noPending).toHaveSuccessfulTx({ to: collection.address });
}

get fun `test v3: ConfirmMint requires pending state and caller funding`() {
    val (collection, _parent, _owner, user) = deployLockedCollection();
    val index = labelIndex("alice");
    val absent = collection.sendConfirmMint(
        user.address,
        1,
        index,
        { value: MIN_CONFIRM_MINT_VALUE, bounce: true },
    );
    expect(absent).toHaveFailedTx({ to: collection.address, exitCode: ERROR_MINT_NOT_PENDING });

    val request = createMessage({
        bounce: true,
        dest: collection.address,
        value: ton("6"),
        body: RegisterSubdomain {
            queryId: 2,
            label: labelSlice("alice").toCell(),
            setWalletToMinter: true,
            content: testOnchainMetadata(),
        },
    });
    testing.processSingleTraceStep(user.address, request);
    val low = collection.sendConfirmMint(
        user.address,
        3,
        index,
        { value: MIN_CONFIRM_MINT_VALUE - 1, bounce: true },
    );
    expect(low).toHaveFailedTx({ to: collection.address, exitCode: ERROR_INSUFFICIENT_BALANCE });
}

get fun `test v3: parent recovery rejects invalid state and protects pending custody`() {
    val (locked, _lockedParent, _lockedOwner, user) = deployLockedCollection();
    val lockedRetry = locked.sendRetryParentReturn(
        user.address,
        1,
        { value: MIN_PARENT_RETURN_VALUE, bounce: true },
    );
    expect(lockedRetry).toHaveFailedTx({ to: locked.address, exitCode: ERROR_LINKED_NO_CUSTODY });

    val (linked, parent, owner, _linkedUser) = deployLinkedCollection();
    val noPending = linked.sendRetryParentReturn(
        user.address,
        2,
        { value: MIN_PARENT_RETURN_VALUE, bounce: true },
    );
    expect(noPending).toHaveFailedTx({ to: linked.address, exitCode: ERROR_NO_PARENT_RETURN });

    val claimed = linked.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 3,
            oldOwnerAddress: owner.address,
            payload: linkedActionPayload(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: MIN_PARENT_RETURN_VALUE, bounce: false },
    );
    expect(claimed).toHaveSuccessfulTx({ to: linked.address });
    val rescue = linked.sendRescueNft(
        owner.address,
        4,
        parent.address,
        owner.address,
        { value: ton("0.2"), bounce: true },
    );
    expect(rescue).toHaveFailedTx({
        to: linked.address,
        exitCode: ERROR_RESCUE_PARENT_FORBIDDEN,
    });

    val returnQueryId = linked.getParentReturn().returnQueryId;
    val acknowledged = linked.sendAny(
        parent.address,
        Excesses { queryId: returnQueryId }.toCell(),
        { value: ton("0.05"), bounce: false },
    );
    expect(acknowledged).toHaveSuccessfulTx({ to: linked.address });
}

get fun `test v3: withdrawal is capped by physical balance`() {
    val accountedRevenue = ton("5");
    val policy: CollectionPolicyState = {
        accessMode: ACCESS_PUBLIC,
        withdrawableRevenue: accountedRevenue,
        allowlist: [],
        pendingMints: [],
        parentGeneration: 0,
        pendingParentReturn: null,
    };
    val (collection, _parent, owner, _user) = deployCollectionWithPolicyAndMeta(
        policy,
        makeMeta(),
        ton("0.2"),
    );
    val balanceBefore = testing.getAccountBalance(collection.address);

    val withdrawal = collection.sendWithdrawFees(
        owner.address,
        20,
        0,
        { value: ton("0.05"), bounce: true },
    );
    expect(withdrawal).toHaveSuccessfulTx({ to: collection.address });
    val payout = withdrawal.findTransaction({ from: collection.address, to: owner.address })!;
    val paid = v3MessageValue(payout.loadInMsg<RemainingBitsAndRefs>().info);
    expect(paid).toBeLessOrEqual(balanceBefore - COLLECTION_MIN_BALANCE - FWD_FEE_RESERVE);
    expect(paid).toBeLess(accountedRevenue);
    expect(collection.getWithdrawableRevenue()).toEqual(accountedRevenue - paid);
}

get fun `test v3: item bounce keeps allowlist membership and clears pending mint`() {
    val (collection, _parent, owner, user) = deployLockedCollection();
    collection.sendSetAccessMode(
        owner.address,
        1,
        ACCESS_ALLOWLIST,
        { value: ton("0.05"), bounce: true },
    );
    collection.sendSetAllowlistEntry(
        owner.address,
        2,
        user.address,
        true,
        { value: ton("0.05"), bounce: true },
    );
    val request = createMessage({
        bounce: true,
        dest: collection.address,
        value: ton("6"),
        body: RegisterSubdomain {
            queryId: 3,
            label: labelSlice("alice").toCell(),
            setWalletToMinter: true,
            content: testOnchainMetadata(),
        },
    });
    val mintStep = testing.processSingleTraceStep(user.address, request);
    expect(collection.getIsAllowlisted(user.address)).toEqual(true);
    val deploy = mintStep.outMessages.at<SubdomainInit>(0);
    val itemAddress = collection.getNftAddressByIndex(labelIndex("alice"));
    var mismatchedInit = deploy.loadBody();
    mismatchedInit.queryId += 1;
    val mismatchedBounce = createMessage({
        bounce: false,
        dest: collection.address,
        value: ton("0.065"),
        body: v3RichBounceBody(mismatchedInit.toCell(), ITEM_DEPLOY_COST),
    }).bounced();
    testing.processSingleTraceStep(itemAddress, mismatchedBounce);
    expect(collection.getIsMintPending(labelIndex("alice"))).toEqual(true);

    val bounced = createMessage({
        bounce: false,
        dest: collection.address,
        value: ton("0.065"),
        body: v3RichBounceBody(deploy.loadBody().toCell(), ITEM_DEPLOY_COST),
    }).bounced();
    testing.processSingleTraceStep(itemAddress, bounced);
    expect(collection.getIsAllowlisted(user.address)).toEqual(true);
    expect(collection.getIsMintPending(labelIndex("alice"))).toEqual(false);
}

get fun `test v3: new getters are total on skeleton and missing entries`() {
    val master = newActor("v3-getter-master");
    val parent = newActor("v3-getter-parent");
    val user = newActor("v3-getter-user");
    val skeleton = SubdomainCollection.fromStorage({
        master: master.address,
        parentDomain: parent.address,
        isLinked: true,
        linkedAdmin: user.address,
    });
    skeleton.deploy(master.address, { value: ton("0.05"), bounce: false });
    expect(skeleton.getIsAllowlisted(user.address)).toEqual(false);
    expect(skeleton.getMintQuote(user.address, 5).allowed).toEqual(false);
    expect(skeleton.getParentReturn().pending).toEqual(false);
    expect(skeleton.getIsMintPending(labelIndex("alice"))).toEqual(false);
    val skeletonResolved = skeleton.dnsresolve(makeLabelDomainSlice("alice"), 0);
    expect(parseNextResolverCell(skeletonResolved.resolvedRecord!)).toEqual(
        skeleton.getNftAddressByIndex(labelIndex("alice")),
    );

    val (collection, _parent2, _owner, _user2) = deployLockedCollection();
    expect(collection.getIsAllowlisted(user.address)).toEqual(false);
    expect(collection.getMintQuote(user.address, 1).allowed).toEqual(false);
    expect(collection.getMintQuote(user.address, MAX_DOMAIN_SIZE + 1).allowed).toEqual(false);
}
