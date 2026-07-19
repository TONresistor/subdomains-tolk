// Regressions for the final v2.0.0 contract review: standards compatibility, authenticated
// deployment acknowledgements, rich-bounce recovery, and previously surviving critical mutants.
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/tlb/either"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/dns-utils"
import "@contracts/errors"
import "@contracts/messages"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "@wrappers/SubdomainFactory.gen"
import "@wrappers/SubdomainItem.gen"
import "test-utils"

fun richBounceBody(originalBody: cell, originalValue: coins): cell {
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

fun internalMessageValue(info: TlbCommonMessageInfo): coins {
    match (info) {
        TlbInternalMessage => return info.value.grams,
        TlbExternalInMessageInfo => return -1,
        TlbExternalOutMessageInfo => return -1,
    }
}

fun expectCarryAllRefund(actual: coins, inbound: coins) {
    expect(actual).toBeGreater(inbound - ton("0.002"));
    expect(actual).toBeLessOrEqual(inbound);
}

get fun `test elite review: pre-compute dust cannot enter factory recovery state`() {
    val owner = newActor("precompute-dust-owner");
    val parent = newActor("precompute-dust-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("0.01"), bounce: false });

    // At one nanotON the TVM skips compute before contract code runs. This pins the protocol boundary:
    // no handler-side validation or recovery write is possible below the execution fee threshold.
    val dust = factory.sendOwnershipAssigned(
        parent.address,
        8,
        owner.address,
        beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        { value: 1, bounce: false },
    );
    expect(
        dust.findTransaction({ to: factory.address, computePhaseSkipped: true }),
    ).toBeNotNull();

    val retry = factory.sendAny(
        owner.address,
        RetryCollectionDeployment {
            queryId: 8,
            collectionAddress: factory.getCollectionAddress(parent.address),
        }.toCell(),
        { value: ton("0.5"), bounce: true },
    );
    expect(retry).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });
}

get fun `test elite review: dust Locked rejection persists an admin-funded custody recovery`() {
    val owner = newActor("dust-rejection-owner");
    val parent = newActor("dust-rejection-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("0.01"), bounce: false });

    // Canonical TON DNS allows a very small notification forward amount. This funds the factory's
    // compute but not a reliable outbound return, so the custody notification must still commit.
    val rejected = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.001"),
        body: OwnershipAssigned {
            queryId: 9,
            oldOwnerAddress: owner.address,
            payload: beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        },
    });
    val first = net.send(parent.address, rejected);
    expect(first).toHaveSuccessfulTx({ to: factory.address });
    val dustReturn = first.findTransaction<TransferOwnership>({
        from: factory.address,
        to: parent.address,
    });
    expect(dustReturn).toEqual(null);

    val expectedCollection = factory.getCollectionAddress(parent.address);
    val retry = factory.sendAny(
        owner.address,
        RetryCollectionDeployment {
            queryId: 10,
            collectionAddress: expectedCollection,
        }.toCell(),
        { value: ton("0.5"), bounce: true },
    );
    expect(retry).toHaveSuccessfulTx({ to: factory.address });
    val returned = retry.findTransaction<TransferOwnership>({
        from: factory.address,
        to: parent.address,
    });
    expect(returned).toBeNotNull();
    val transfer = returned!.loadInMsg<TransferOwnership>().body;
    val returnBody = match (transfer) {
        TlbEitherLeft => transfer.value,
        TlbEitherRight => transfer.value.load(),
    };
    expect(returnBody.transferData.newOwnerAddress).toEqual(owner.address);
    expect(returnBody.transferData.responseDestination).toEqual(factory.address);

    // Only the canonical parent's generation-bound acknowledgement clears custody recovery.
    val ack = factory.sendAny(
        parent.address,
        Excesses { queryId: returnBody.queryId }.toCell(),
        { value: ton("0.01"), bounce: false },
    );
    expect(ack).toHaveSuccessfulTx({ to: factory.address });
    val cleared = factory.sendAny(
        owner.address,
        RetryCollectionDeployment {
            queryId: 11,
            collectionAddress: expectedCollection,
        }.toCell(),
        { value: ton("0.5"), bounce: true },
    );
    expect(cleared).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });
}

get fun `test elite review: hash-addressed collection reports TEP-62 next index minus one`() {
    val (coll, _parent, owner, user) = deployLockedCollection();
    expect(coll.getCollectionData().nextItemIndex).toEqual(-1);

    val (_item, _res) = mintSubdomain(coll, user, "alice");
    expect(coll.getMintedCount()).toEqual(1);
    expect(coll.getIsMintPending(labelIndex("alice"))).toEqual(false);
    expect(coll.getCollectionData().nextItemIndex).toEqual(-1);
    expect(coll.getCollectionData().ownerAddress).toEqual(owner.address);

    val skeletonMaster = newActor("tep62-skeleton-master");
    val skeletonParent = newActor("tep62-skeleton-parent");
    val skeleton = SubdomainCollection.fromStorage({
        master: skeletonMaster.address,
        parentDomain: skeletonParent.address,
        isLinked: false,
        linkedAdmin: skeletonMaster.address,
    });
    skeleton.deploy(skeletonMaster.address, { value: ton("0.05"), bounce: false });
    expect(skeleton.getCollectionData().nextItemIndex).toEqual(-1);
    expect(skeleton.getCollectionData().ownerAddress).toEqual(null);
}

get fun `test elite review: failed item deploy rolls the label back and refunds`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val attacker = newActor("item-bounce-attacker");
    val register = createMessage({
        bounce: true,
        dest: coll.address,
        value: ton("20"),
        body: RegisterSubdomain {
            queryId: 71,
            label: labelSlice("alice").toCell(),
            setWalletToMinter: true,
        },
    });

    // Execute only the collection transaction: its item deployment remains undelivered.
    val mintStep = testing.processSingleTraceStep(user.address, register);
    expect(coll.getMintedCount()).toEqual(0);
    expect(coll.getIsMintPending(labelIndex("alice"))).toEqual(true);
    val deployOut = mintStep.outMessages.at<SubdomainInit>(0);
    val originalInit = deployOut.loadBody();
    val itemAddress = coll.getNftAddressByIndex(labelIndex("alice"));

    val bouncedBody = richBounceBody(originalInit.toCell(), ITEM_DEPLOY_COST);
    val unauthenticated = createMessage({
        bounce: false,
        dest: coll.address,
        value: ton("0.065"),
        body: bouncedBody,
    }).bounced();
    val badSender = net.send(attacker.address, unauthenticated);
    expect(badSender).toHaveFailedTx({ to: coll.address, exitCode: ERROR_NOT_FROM_COLLECTION });

    var wrongLabel = originalInit;
    wrongLabel.label = labelSlice("bobby").toCell();
    val mismatched = net.send(
        itemAddress,
        createMessage({
            bounce: false,
            dest: coll.address,
            value: ton("0.065"),
            body: richBounceBody(wrongLabel.toCell(), ITEM_DEPLOY_COST),
        }).bounced(),
    );
    expect(mismatched).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INDEX_MISMATCH });

    val bounced = createMessage({
        bounce: false,
        dest: coll.address,
        value: ton("0.065"),
        body: richBounceBody(originalInit.toCell(), ITEM_DEPLOY_COST),
    }).bounced();
    val rollback = testing.processSingleTraceStep(itemAddress, bounced);

    expect(coll.getMintedCount()).toEqual(0);
    expect(coll.getIsMintPending(labelIndex("alice"))).toEqual(false);
    expect(rollback.outMessages.size()).toEqual(1);
    val refund = rollback.outMessages.at<Excesses>(0);
    expect(refund.loadBody().queryId).toEqual(71);
    expect(refund.info.value.grams).toEqual(ton("5.065"));

    // The rollback really frees the hash slot; a normal retry deploys the item.
    val (retried, _retryRes) = mintSubdomain(coll, user, "alice");
    expect(testing.isDeployed(retried.address)).toEqual(true);
}

get fun `test elite review: failed Locked collection deploy returns custody and clears pending`() {
    val owner = newActor("bounce-owner");
    val parent = newActor("bounce-parent");
    val attacker = newActor("bounce-attacker");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val request = createMessage({
        bounce: false,
        dest: factory.address,
        value: MIN_CREATE_VALUE,
        body: OwnershipAssigned {
            queryId: 81,
            oldOwnerAddress: owner.address,
            payload: beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        },
    });
    val createStep = testing.processSingleTraceStep(parent.address, request);
    val deployOut = createStep.outMessages.at<LockCollection>(0);
    val originalLock = deployOut.loadBody();
    val expectedCollection = factory.getCollectionAddress(parent.address);

    val unauthenticated = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.24"),
        body: richBounceBody(originalLock.toCell(), COLLECTION_DEPLOY_VALUE),
    }).bounced();
    val badSender = net.send(attacker.address, unauthenticated);
    expect(badSender).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    var wrongAdmin = originalLock;
    wrongAdmin.admin = attacker.address;
    val badAdmin = net.send(
        expectedCollection,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("0.24"),
            body: richBounceBody(wrongAdmin.toCell(), COLLECTION_DEPLOY_VALUE),
        }).bounced(),
    );
    expect(badAdmin).toHaveFailedTx({ to: factory.address, exitCode: ERROR_NOT_FROM_COLLECTION });

    var wrongQuery = originalLock;
    wrongQuery.queryId = 82;
    val badQuery = net.send(
        expectedCollection,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("0.24"),
            body: richBounceBody(wrongQuery.toCell(), COLLECTION_DEPLOY_VALUE),
        }).bounced(),
    );
    expect(badQuery).toHaveFailedTx({ to: factory.address, exitCode: ERROR_NOT_FROM_COLLECTION });

    var changedMeta = makeMeta();
    changedMeta.collectionContent = beginCell().storeUint(1, 1).endCell();
    var wrongMeta = originalLock;
    wrongMeta.meta = changedMeta.toCell();
    val badMeta = net.send(
        expectedCollection,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("0.24"),
            body: richBounceBody(wrongMeta.toCell(), COLLECTION_DEPLOY_VALUE),
        }).bounced(),
    );
    expect(badMeta).toHaveFailedTx({ to: factory.address, exitCode: ERROR_NOT_FROM_COLLECTION });

    val bounced = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.24"),
        body: richBounceBody(originalLock.toCell(), COLLECTION_DEPLOY_VALUE),
    }).bounced();
    val recovery = testing.processSingleTraceStep(expectedCollection, bounced);

    expect(recovery.outMessages.size()).toEqual(1);
    val handoffMessage = recovery.outMessages.at<TransferOwnership>(0);
    expect(handoffMessage.info.value.grams).toEqual(
        ton("0.24") + MIN_CREATE_VALUE - COLLECTION_DEPLOY_VALUE - FACTORY_GAS_MARGIN,
    );
    val handoff = handoffMessage.loadBody();
    expect(handoff.transferData.newOwnerAddress).toEqual(owner.address);

    // The return stays recoverable until the canonical parent acknowledges its transfer.
    val replay = testing.processSingleTraceStep(expectedCollection, bounced);
    expect(replay.outMessages.size()).toEqual(1);
    val replayRefund = replay.outMessages.at<Excesses>(0);
    expect(replayRefund.loadBody().queryId).toEqual(81);
    expectCarryAllRefund(replayRefund.info.value.grams, ton("0.24"));
    val factoryBalanceBeforeReturnAck = testing.getAccountBalance(factory.address);
    val returnAck = factory.sendAny(
        parent.address,
        Excesses { queryId: handoff.queryId }.toCell(),
        { value: ton("0.21"), bounce: false },
    );
    expect(returnAck).toHaveSuccessfulTx({ to: factory.address });
    expect(testing.getAccountBalance(factory.address)).toBeLessOrEqual(
        factoryBalanceBeforeReturnAck,
    );
    val deployBounceRefund = returnAck.findTransaction<Excesses>({
        from: factory.address,
        to: owner.address,
    })!;
    expect(deployBounceRefund.loadBody<Excesses>().queryId).toEqual(81);
    expectCarryAllRefund(
        internalMessageValue(deployBounceRefund.loadInMsg<Excesses>().info),
        ton("0.21"),
    );
    // Crossed failed attempts: a delayed deploy bounce can arrive after another failure's parent
    // return acknowledgement cleared pending, while no collection was ever deployed.
    val postAckLateStep = testing.processSingleTraceStep(expectedCollection, bounced);
    val postAckLateRefund = postAckLateStep.outMessages.at<Excesses>(0);
    expect(postAckLateRefund.loadBody().queryId).toEqual(81);
    expectCarryAllRefund(postAckLateRefund.info.value.grams, ton("0.24"));

    // A stale transfer bounce cannot mutate or pay from an already completed generation.
    val delayedReturnBounce = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.47"),
        body: richBounceBody(handoff.toCell(), ton("0.48")),
    }).bounced();
    val delayedReturnStep = testing.processSingleTraceStep(parent.address, delayedReturnBounce);
    expect(delayedReturnStep.outMessages.size()).toEqual(0);
    val noLongerPending = factory.sendAny(
        owner.address,
        RetryCollectionDeployment {
            queryId: 83,
            collectionAddress: expectedCollection,
        }.toCell(),
        { value: ton("0.5"), bounce: true },
    );
    expect(noLongerPending).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });
}

get fun `test elite review: admin can recover a Locked deployment whose ready callback was lost`() {
    val owner = newActor("retry-locked-owner");
    val parent = newActor("retry-locked-parent");
    val attacker = newActor("retry-locked-attacker");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val request = createMessage({
        bounce: false,
        dest: factory.address,
        value: MIN_CREATE_VALUE,
        body: OwnershipAssigned {
            queryId: 91,
            oldOwnerAddress: owner.address,
            payload: beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        },
    });
    val createStep = testing.processSingleTraceStep(parent.address, request);
    val expectedCollection = factory.getCollectionAddress(parent.address);
    val originalLock = createStep.outMessages.at<LockCollection>(0).loadBody();

    // Deliver only the deployment. Its CollectionReady output is deliberately left undelivered.
    val deployMessage = OutMessage { messageCell: createStep.outMessages.atCell(0) };
    testing.processSingleTraceStep(factory.address, deployMessage);
    expect(testing.isDeployed(expectedCollection)).toEqual(true);

    val correctReady: CollectionReady = {
        deploymentId: originalLock.deploymentId,
        queryId: 91,
        parentDomain: parent.address,
        admin: owner.address,
        currentAdmin: owner.address,
        isLinked: false,
        isNew: true,
    };
    val badReadySender = factory.sendAny(
        attacker.address,
        correctReady.toCell(),
        { value: ton("0.02"), bounce: true },
    );
    expect(badReadySender).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    var wrongReadyAdmin = correctReady;
    wrongReadyAdmin.admin = attacker.address;
    val badReadyAdmin = factory.sendAny(
        expectedCollection,
        wrongReadyAdmin.toCell(),
        { value: ton("0.02"), bounce: true },
    );
    expect(badReadyAdmin).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    var wrongReadyQuery = correctReady;
    wrongReadyQuery.queryId = 999;
    val badReadyQuery = factory.sendAny(
        expectedCollection,
        wrongReadyQuery.toCell(),
        { value: ton("0.02"), bounce: true },
    );
    expect(badReadyQuery).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    val underfundedRetry = factory.sendAny(
        owner.address,
        RetryCollectionDeployment {
            queryId: 92,
            collectionAddress: expectedCollection,
        }.toCell(),
        { value: COLLECTION_DEPLOY_VALUE + FACTORY_GAS_MARGIN - 1, bounce: true },
    );
    expect(underfundedRetry).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_INSUFFICIENT_BALANCE,
    });

    val attackerRetry = factory.sendAny(
        attacker.address,
        RetryCollectionDeployment {
            queryId: 92,
            collectionAddress: expectedCollection,
        }.toCell(),
        { value: ton("0.5"), bounce: true },
    );
    expect(attackerRetry).toHaveFailedTx({ to: factory.address, exitCode: ERROR_NOT_ADMIN });

    val (_, expectedHash) = expectedCollection.getWorkchainAndHash();
    val wrongWorkchain = address.fromWorkchainAndHash(MASTERCHAIN, expectedHash);
    val wrongAddressRetry = factory.sendAny(
        owner.address,
        RetryCollectionDeployment {
            queryId: 92,
            collectionAddress: wrongWorkchain,
        }.toCell(),
        { value: ton("0.5"), bounce: true },
    );
    expect(wrongAddressRetry).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    val retry = factory.sendAny(
        owner.address,
        RetryCollectionDeployment {
            queryId: 92,
            collectionAddress: expectedCollection,
        }.toCell(),
        { value: ton("0.5"), bounce: true },
    );
    expect(retry).toHaveSuccessfulTx({ to: factory.address });
    expect(
        retry.findTransaction<TransferOwnership>({ from: factory.address, to: parent.address }),
    ).toBeNotNull();

    // The first deploy attempt can bounce after a retry has already advanced the generation to the
    // handoff phase. Refund that delayed value without rolling the phase or custody state back.
    val delayedDeployBounce = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.24"),
        body: richBounceBody(originalLock.toCell(), COLLECTION_DEPLOY_VALUE),
    }).bounced();
    val delayedRefundStep = testing.processSingleTraceStep(expectedCollection, delayedDeployBounce);
    val delayedRefund = delayedRefundStep.outMessages.at<Excesses>(0);
    expect(delayedRefund.loadBody().queryId).toEqual(91);
    expectCarryAllRefund(delayedRefund.info.value.grams, ton("0.24"));

    // The factory retains pending until the collection proves the parent actually landed.
    val handoffTx = retry.findTransaction<TransferOwnership>({
        from: factory.address,
        to: parent.address,
    })!;
    val handoff = handoffTx.loadInMsg<TransferOwnership>().body;
    val transfer = match (handoff) {
        TlbEitherLeft => handoff.value,
        TlbEitherRight => handoff.value.load(),
    };
    val landed = createMessage({
        bounce: false,
        dest: expectedCollection,
        value: RESOLVER_PIN_FUND,
        body: OwnershipAssigned {
            queryId: transfer.queryId,
            oldOwnerAddress: factory.address,
            payload: transfer.transferData.forwardPayload,
        },
    });
    val collectionLanding = testing.processSingleTraceStep(parent.address, landed);
    val _droppedCompletion = collectionLanding.outMessages.at<ParentHandoffComplete>(1);

    // A later admin transfer must not make receipt recovery misclassify a completed custody handoff
    // as the old-admin reauction race and return the permanently Locked parent.
    val newAdmin = newActor("retry-locked-new-admin");
    val activeCollection = SubdomainCollection.fromAddress(expectedCollection);
    val transferredAdmin = activeCollection.sendTransferAdmin(
        owner.address,
        92,
        newAdmin.address,
        { value: ton("0.1"), bounce: true },
    );
    expect(transferredAdmin).toHaveSuccessfulTx({ to: expectedCollection });

    // Drop that final callback too. A phase-aware retry probes the collection's persisted receipt,
    // re-emits the authenticated completion, and clears pending without guessing custody state.
    val finalRetry = factory.sendAny(
        owner.address,
        RetryCollectionDeployment {
            queryId: 93,
            collectionAddress: expectedCollection,
        }.toCell(),
        { value: ton("0.5"), bounce: true },
    );
    expect(finalRetry).toHaveSuccessfulTx({ to: factory.address });
    expect(
        finalRetry.findTransaction<ParentHandoffComplete>({
            from: expectedCollection,
            to: factory.address,
        }),
    ).toBeNotNull();
    expect(
        finalRetry.findTransaction<TransferOwnership>({
            from: expectedCollection,
            to: parent.address,
        }),
    ).toEqual(null);

    val noLongerPending = factory.sendAny(
        owner.address,
        RetryCollectionDeployment {
            queryId: 94,
            collectionAddress: expectedCollection,
        }.toCell(),
        { value: ton("0.5"), bounce: true },
    );
    expect(noLongerPending).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    // A still-later authenticated bounce after completion is also refunded from the deployed record.
    val completedRefundStep = testing.processSingleTraceStep(
        expectedCollection,
        delayedDeployBounce,
    );
    val completedRefund = completedRefundStep.outMessages.at<Excesses>(0);
    expect(completedRefund.loadBody().queryId).toEqual(91);
    expectCarryAllRefund(completedRefund.info.value.grams, ton("0.24"));

    val lateComplete = factory.sendAny(
        expectedCollection,
        ParentHandoffComplete {
            deploymentId: originalLock.deploymentId,
            queryId: 91,
            parentDomain: parent.address,
            intendedAdmin: owner.address,
        }.toCell(),
        { value: ton("0.02"), bounce: false },
    );
    val lateCompleteRefund = lateComplete.findTransaction<Excesses>({
        from: factory.address,
        to: owner.address,
    })!;
    expect(lateCompleteRefund.loadBody<Excesses>().queryId).toEqual(91);
    expectCarryAllRefund(
        internalMessageValue(lateCompleteRefund.loadInMsg<Excesses>().info),
        ton("0.02"),
    );

    val lateReady = factory.sendAny(
        expectedCollection,
        correctReady.toCell(),
        { value: ton("0.02"), bounce: false },
    );
    val lateReadyRefund = lateReady.findTransaction<Excesses>({
        from: factory.address,
        to: owner.address,
    })!;
    expect(lateReadyRefund.loadBody<Excesses>().queryId).toEqual(91);
    expectCarryAllRefund(
        internalMessageValue(lateReadyRefund.loadInMsg<Excesses>().info),
        ton("0.02"),
    );
}

get fun `test elite review: Linked create retries an in-flight request without overwriting it`() {
    val owner = newActor("pending-owner");
    val parent = newActor("pending-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val first = createMessage({
        bounce: true,
        dest: factory.address,
        value: ton("0.5"),
        body: CreateLinkedCollection {
            queryId: 1,
            parentDomain: parent.address,
            admin: owner.address,
            meta: makeMeta().toCell(),
        },
    });
    testing.processSingleTraceStep(owner.address, first);

    var changedMeta = makeMeta();
    changedMeta.collectionContent = beginCell().storeUint(1, 1).endCell();
    val changedConfig = factory.sendCreateLinkedCollection(
        owner.address,
        2,
        parent.address,
        owner.address,
        changedMeta,
        { value: ton("0.5"), bounce: true },
    );
    expect(changedConfig).toHaveFailedTx({ to: factory.address, exitCode: ERROR_UNKNOWN_OP });

    val second = factory.sendCreateLinkedCollection(
        owner.address,
        3,
        parent.address,
        owner.address,
        makeMeta(),
        { value: ton("0.5"), bounce: true },
    );
    expect(second).toHaveSuccessfulTx({ to: factory.address });
    expect(
        testing.isDeployed(factory.getLinkedCollectionAddress(parent.address, owner.address)),
    ).toEqual(true);
}

get fun `test elite review: reauctioned Locked parent bypasses the old-admin collection`() {
    val oldOwner = newActor("reauction-old-owner");
    val newOwner = newActor("reauction-new-owner");
    val parent = newActor("reauction-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(oldOwner.address, { value: ton("1"), bounce: false });

    val first = factory.sendOwnershipAssigned(
        parent.address,
        501,
        oldOwner.address,
        beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        { value: MIN_CREATE_VALUE, bounce: false },
    );
    val collection = factory.getCollectionAddress(parent.address);
    val firstHandoffTx = first.findTransaction<TransferOwnership>({
        from: factory.address,
        to: parent.address,
    })!;
    val firstEither = firstHandoffTx.loadInMsg<TransferOwnership>().body;
    val firstHandoff = match (firstEither) {
        TlbEitherLeft => firstEither.value,
        TlbEitherRight => firstEither.value.load(),
    };
    val firstLanding = createMessage({
        bounce: false,
        dest: collection,
        value: RESOLVER_PIN_FUND,
        body: OwnershipAssigned {
            queryId: firstHandoff.queryId,
            oldOwnerAddress: factory.address,
            payload: firstHandoff.transferData.forwardPayload,
        },
    });
    val firstCompleted = net.send(parent.address, firstLanding);
    expect(firstCompleted).toHaveSuccessfulTx({ to: factory.address });

    // The same deterministic collection is active under oldOwner. Its duplicate-ready callback now
    // reports that real current admin, so the factory returns the reauctioned parent directly to the
    // winner instead of passing custody through the old registry.
    val second = factory.sendOwnershipAssigned(
        parent.address,
        502,
        newOwner.address,
        beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        { value: MIN_CREATE_VALUE, bounce: false },
    );
    val returnTx = second.findTransaction<TransferOwnership>({
        from: factory.address,
        to: parent.address,
    })!;
    val returnEither = returnTx.loadInMsg<TransferOwnership>().body;
    val returned = match (returnEither) {
        TlbEitherLeft => returnEither.value,
        TlbEitherRight => returnEither.value.load(),
    };
    expect(returned.transferData.newOwnerAddress).toEqual(newOwner.address);
    expect(returned.transferData.forwardAmount).toEqual(0);
    expect(returned.transferData.responseDestination).toEqual(factory.address);

    val factoryBalanceBeforeReauctionAck = testing.getAccountBalance(factory.address);
    val acknowledged = factory.sendAny(
        parent.address,
        Excesses { queryId: returned.queryId }.toCell(),
        { value: ton("0.31"), bounce: false },
    );
    expect(acknowledged).toHaveSuccessfulTx({ to: factory.address });
    expect(testing.getAccountBalance(factory.address)).toBeLessOrEqual(
        factoryBalanceBeforeReauctionAck,
    );
    val reauctionRefund = acknowledged.findTransaction<Excesses>({
        from: factory.address,
        to: newOwner.address,
    })!;
    expect(reauctionRefund.loadBody<Excesses>().queryId).toEqual(502);
    expectCarryAllRefund(
        internalMessageValue(reauctionRefund.loadInMsg<Excesses>().info),
        ton("0.31"),
    );
    val cleared = factory.sendAny(
        newOwner.address,
        RetryCollectionDeployment {
            queryId: 503,
            collectionAddress: collection,
        }.toCell(),
        { value: ton("0.5"), bounce: true },
    );
    expect(cleared).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });
}

get fun `test elite review: admin transfer during Locked handoff returns parent and clears pending`() {
    val initialAdmin = newActor("handoff-race-initial-admin");
    val nextAdmin = newActor("handoff-race-next-admin");
    val parent = newActor("handoff-race-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(initialAdmin.address, { value: ton("1"), bounce: false });

    val created = factory.sendOwnershipAssigned(
        parent.address,
        601,
        initialAdmin.address,
        beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        { value: MIN_CREATE_VALUE, bounce: false },
    );
    val collectionAddress = factory.getCollectionAddress(parent.address);
    val handoffTx = created.findTransaction<TransferOwnership>({
        from: factory.address,
        to: parent.address,
    })!;
    val handoffEither = handoffTx.loadInMsg<TransferOwnership>().body;
    val handoff = match (handoffEither) {
        TlbEitherLeft => handoffEither.value,
        TlbEitherRight => handoffEither.value.load(),
    };

    // Change collection authority after Ready but before the parent's OwnershipAssigned delivery.
    val collection = SubdomainCollection.fromAddress(collectionAddress);
    val adminChanged = collection.sendTransferAdmin(
        initialAdmin.address,
        602,
        nextAdmin.address,
        { value: ton("0.1"), bounce: true },
    );
    expect(adminChanged).toHaveSuccessfulTx({ to: collectionAddress });

    val landing = createMessage({
        bounce: false,
        dest: collectionAddress,
        value: RESOLVER_PIN_FUND,
        body: OwnershipAssigned {
            queryId: handoff.queryId,
            oldOwnerAddress: factory.address,
            payload: handoff.transferData.forwardPayload,
        },
    });
    val landingStep = testing.processSingleTraceStep(parent.address, landing);
    val returned = landingStep.outMessages.at<TransferOwnership>(0).loadBody();
    expect(returned.transferData.newOwnerAddress).toEqual(initialAdmin.address);
    expect(returned.transferData.responseDestination).toEqual(factory.address);

    // The canonical parent's acknowledgement is valid while factory state is still
    // PHASE_AWAITING_HANDOFF; it proves the race-return completed and must clear pending.
    val factoryBalanceBeforeRaceAck = testing.getAccountBalance(factory.address);
    val acknowledged = factory.sendAny(
        parent.address,
        Excesses { queryId: returned.queryId }.toCell(),
        { value: ton("0.41"), bounce: false },
    );
    expect(acknowledged).toHaveSuccessfulTx({ to: factory.address });
    expect(testing.getAccountBalance(factory.address)).toBeLessOrEqual(factoryBalanceBeforeRaceAck);
    val raceRefund = acknowledged.findTransaction<Excesses>({
        from: factory.address,
        to: initialAdmin.address,
    })!;
    expect(raceRefund.loadBody<Excesses>().queryId).toEqual(601);
    expectCarryAllRefund(
        internalMessageValue(raceRefund.loadInMsg<Excesses>().info),
        ton("0.41"),
    );
    val cleared = factory.sendAny(
        initialAdmin.address,
        RetryCollectionDeployment {
            queryId: 603,
            collectionAddress,
        }.toCell(),
        { value: ton("0.5"), bounce: true },
    );
    expect(cleared).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });
}

get fun `test elite review: factory rejects null owner and unknown op`() {
    val caller = newActor("factory-negative");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(caller.address, { value: ton("1"), bounce: false });

    val nullOwner = factory.sendOwnershipAssigned(
        caller.address,
        1,
        null,
        emptyPayload(),
        { value: ton("0.5"), bounce: true },
    );
    expect(nullOwner).toHaveFailedTx({ to: factory.address, exitCode: ERROR_NULL_OLD_OWNER });

    val unknown = factory.sendAny(
        caller.address,
        beginCell().storeUint(0xdeadbeef, 32).endCell(),
        { value: ton("0.1"), bounce: true },
    );
    expect(unknown).toHaveFailedTx({ to: factory.address, exitCode: ERROR_UNKNOWN_OP });
}

get fun `test elite review: collection rejects 127-byte labels and unknown ops`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val tooLong = beginCell()
        .storeUint(0, 256)
        .storeUint(0, 256)
        .storeUint(0, 256)
        .storeUint(0, 248)
        .endCell()
        .beginParse();
    val longResult = coll.sendRegisterSubdomain(
        user.address,
        1,
        tooLong,
        true,
        { value: ton("100"), bounce: true },
    );
    expect(longResult).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_TOO_LONG });

    var maxLabelBuilder = beginCell();
    repeat (MAX_DOMAIN_SIZE) {
        maxLabelBuilder.storeUint(97, BYTE_SIZE); // 'a'
    }
    val maxLabel = maxLabelBuilder.endCell().beginParse();
    val maxResult = coll.sendRegisterSubdomain(
        user.address,
        2,
        maxLabel,
        true,
        { value: ton("1"), bounce: true },
    );
    expect(maxResult).toHaveSuccessfulTx({ to: coll.address });

    val unknown = coll.sendAny(
        user.address,
        beginCell().storeUint(0xdeadbeef, 32).endCell(),
        { value: ton("0.1"), bounce: true },
    );
    expect(unknown).toHaveFailedTx({ to: coll.address, exitCode: ERROR_UNKNOWN_OP });
}

get fun `test elite review: collection validates skeleton and duplicate deployment identity`() {
    val master = newActor("identity-master");
    val parent = newActor("identity-parent");
    val otherParent = newActor("identity-other-parent");
    val owner = newActor("identity-owner");
    val skeleton = SubdomainCollection.fromStorage({
        master: master.address,
        parentDomain: parent.address,
        isLinked: false,
        linkedAdmin: master.address,
    });
    skeleton.deploy(master.address, { value: ton("0.05"), bounce: false });

    val wrongParent = skeleton.sendAny(
        master.address,
        LockCollection {
            queryId: 1,
            parentDomain: otherParent.address,
            admin: owner.address,
            isLinked: false,
            meta: makeMeta().toCell(),
        }.toCell(),
        { value: ton("0.25"), bounce: true },
    );
    expect(wrongParent).toHaveFailedTx({ to: skeleton.address, exitCode: ERROR_NOT_FROM_MASTER });

    val wrongMode = skeleton.sendAny(
        master.address,
        LockCollection {
            queryId: 2,
            parentDomain: parent.address,
            admin: owner.address,
            isLinked: true,
            meta: makeMeta().toCell(),
        }.toCell(),
        { value: ton("0.25"), bounce: true },
    );
    expect(wrongMode).toHaveFailedTx({ to: skeleton.address, exitCode: ERROR_NOT_FROM_MASTER });

    val (active, activeParent, _activeOwner, _user) = deployLockedCollection();
    val activeMaster = active.getLinkedAdmin();
    val badDuplicateParent = active.sendAny(
        activeMaster,
        LockCollection {
            queryId: 3,
            parentDomain: otherParent.address,
            admin: owner.address,
            isLinked: false,
            meta: makeMeta().toCell(),
        }.toCell(),
        { value: ton("0.25"), bounce: true },
    );
    expect(badDuplicateParent).toHaveFailedTx({
        to: active.address,
        exitCode: ERROR_NOT_FROM_MASTER,
    });

    val badDuplicateMode = active.sendAny(
        activeMaster,
        LockCollection {
            queryId: 4,
            parentDomain: activeParent.address,
            admin: owner.address,
            isLinked: true,
            meta: makeMeta().toCell(),
        }.toCell(),
        { value: ton("0.25"), bounce: true },
    );
    expect(badDuplicateMode).toHaveFailedTx({
        to: active.address,
        exitCode: ERROR_NOT_FROM_MASTER,
    });
}

get fun `test elite review: item init authenticates sender, index and label`() {
    val collection = newActor("init-collection");
    val attacker = newActor("init-attacker");
    val aliceIndex = labelIndex("alice");
    val item = SubdomainItem.fromStorage({
        index: aliceIndex,
        collectionAddress: collection.address,
    });
    val stateInit = item.stateInit!;

    val correctInit: SubdomainInit = {
        queryId: 1,
        index: aliceIndex,
        minter: collection.address,
        label: labelSlice("alice").toCell(),
        setWalletToMinter: false,
    };
    val fakeSender = net.send(
        attacker.address,
        createMessage({
            bounce: true,
            dest: AutoDeployAddress {
                workchain: BASECHAIN,
                stateInit,
            },
            value: ton("0.1"),
            body: correctInit,
        }),
    );
    expect(fakeSender).toHaveFailedTx({ to: item.address, exitCode: ERROR_NOT_FROM_COLLECTION });
    // TON may retain the StateInit after a failed deploy transaction, but initialization must not
    // commit: the item stays in its canonical uninitialized TEP-62 state.
    expect(item.getNftData().isInitialized).toEqual(false);
    expect(item.getEditor()).toEqual(null);
    expect(item.getDomain().remainingBitsCount()).toEqual(0);
    val unresolved = item.dnsresolve(makeDotSlice(), 0);
    expect(unresolved.resolvedPrefixLengthBits).toEqual(0);
    expect(unresolved.resolvedRecord).toEqual(null);

    var wrongIndex = correctInit;
    wrongIndex.index = labelIndex("bob");
    val badIndex = net.send(
        collection.address,
        createMessage({
            bounce: true,
            dest: AutoDeployAddress {
                workchain: BASECHAIN,
                stateInit,
            },
            value: ton("0.1"),
            body: wrongIndex,
        }),
    );
    expect(badIndex).toHaveFailedTx({ to: item.address, exitCode: ERROR_INDEX_MISMATCH });
    expect(item.getNftData().isInitialized).toEqual(false);

    var wrongLabel = correctInit;
    wrongLabel.label = labelSlice("bobby").toCell();
    val badLabel = net.send(
        collection.address,
        createMessage({
            bounce: true,
            dest: AutoDeployAddress {
                workchain: BASECHAIN,
                stateInit,
            },
            value: ton("0.1"),
            body: wrongLabel,
        }),
    );
    expect(badLabel).toHaveFailedTx({ to: item.address, exitCode: ERROR_INDEX_MISMATCH });
    expect(item.getNftData().isInitialized).toEqual(false);
}

get fun `test elite review: item rejects unauthorized edit, insolvent transfer and unknown op`() {
    val (coll, _parent, owner, user) = deployLockedCollection();
    val (item, _mint) = mintSubdomain(coll, user, "alice");

    val records: DnsRecords = [];
    val edit = item.sendEditContent(owner.address, 1, records, { value: ton("0.1"), bounce: true });
    expect(edit).toHaveFailedTx({ to: item.address, exitCode: ERROR_NOT_OWNER });

    val insolvent = item.sendTransferOwnership(
        user.address,
        2,
        makeTransferData(owner.address, user.address, ton("1")),
        { value: ton("0.001"), bounce: true },
    );
    expect(insolvent).toHaveFailedTx({ to: item.address, exitCode: ERROR_INSUFFICIENT_BALANCE });
    expect(item.getEditor()).toEqual(user.address);

    val unknown = item.sendAny(
        user.address,
        beginCell().storeUint(0xdeadbeef, 32).endCell(),
        { value: ton("0.1"), bounce: true },
    );
    expect(unknown).toHaveFailedTx({ to: item.address, exitCode: ERROR_UNKNOWN_OP });
}

get fun `test elite review: item transfer optional branches emit only requested messages`() {
    val (coll, _parent, owner, user) = deployLockedCollection();
    val receiverA = newActor("transfer-a");
    val receiverB = newActor("transfer-b");

    val (forwardedItem, _mintA) = mintSubdomain(coll, user, "alpha");
    val forwardOnly = forwardedItem.sendTransferOwnership(
        user.address,
        1,
        makeTransferData(receiverA.address, null, ton("0.01")),
        { value: ton("0.2"), bounce: true },
    );
    expect(
        forwardOnly.findTransaction<OwnershipAssigned>({
            from: forwardedItem.address,
            to: receiverA.address,
        }),
    ).toBeNotNull();
    expect(
        forwardOnly.findTransaction<Excesses>({ from: forwardedItem.address }),
    ).toEqual(null);

    val (responseItem, _mintB) = mintSubdomain(coll, user, "bravo");
    val responseOnly = responseItem.sendTransferOwnership(
        user.address,
        2,
        makeTransferData(receiverB.address, user.address, 0),
        { value: ton("0.2"), bounce: true },
    );
    expect(
        responseOnly.findTransaction<OwnershipAssigned>({ from: responseItem.address }),
    ).toEqual(null);
    expect(
        responseOnly.findTransaction<Excesses>({
            from: responseItem.address,
            to: user.address,
        }),
    ).toBeNotNull();

    val (silentItem, _mintC) = mintSubdomain(coll, user, "charlie");
    val silent = silentItem.sendTransferOwnership(
        user.address,
        3,
        makeTransferData(owner.address, null, 0),
        { value: ton("0.2"), bounce: true },
    );
    expect(silent).toHaveSuccessfulTx({ to: silentItem.address });
    expect(silent.findTransaction({ from: silentItem.address })).toEqual(null);
    expect(silentItem.getEditor()).toEqual(owner.address);
}

get fun `test elite review: setWalletToMinter false leaves the wallet record absent`() {
    val (coll, _parent, _owner, user) = deployLockedCollection();
    val label = "nowallet";
    val mint = coll.sendRegisterSubdomain(
        user.address,
        1,
        labelSlice(label),
        false,
        { value: ton("20"), bounce: true },
    );
    expect(mint).toHaveSuccessfulTx({ to: coll.address });
    val item = SubdomainItem.fromAddress(coll.getNftAddressByIndex(labelIndex(label)));
    expect(item.dnsresolve(makeDotSlice(), CAT_WALLET).resolvedRecord).toEqual(null);
}

get fun `test elite review: shared DNS validation rejects ragged, empty and non-root queries`() {
    val ragged = beginCell().storeUint(0, 9).endCell().beginParse();

    var raggedExit = -1;
    try {
        val _ignoredRagged = dnsQueryStartsWithZero(ragged);
    } catch (exitCode) {
        raggedExit = exitCode;
    }
    expect(raggedExit).toEqual(ERROR_DNS_INVALID_SUBDOMAIN_BITS);

    var emptyExit = -1;
    try {
        val _ignoredEmpty = dnsQueryStartsWithZero(emptyPayload());
    } catch (exitCode) {
        emptyExit = exitCode;
    }
    expect(emptyExit).toEqual(ERROR_DNS_INVALID_SUBDOMAIN_BITS);

    var missingZeroExit = -1;
    try {
        assertDnsQueryStartsWithZero(labelSlice("x"));
    } catch (exitCode) {
        missingZeroExit = exitCode;
    }
    expect(missingZeroExit).toEqual(ERROR_DNS_INVALID_SUBDOMAIN_BITS);

    expect(dnsQueryStartsWithZero(makeDotSlice())).toEqual(true);

    val (coll, _parent, _owner, _user) = deployLockedCollection();
    val withLeadingZero = coll.dnsresolve(makeLeadingZero(makeLabelDomainSlice("alice")), 0);
    expect(withLeadingZero.resolvedPrefixLengthBits).toEqual(48);
    expect(parseNextResolverCell(withLeadingZero.resolvedRecord!)).toEqual(
        coll.getNftAddressByIndex(labelIndex("alice")),
    );
}
