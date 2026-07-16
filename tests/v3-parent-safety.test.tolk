import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/message"
import "@contracts/errors"
import "@contracts/messages"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "@wrappers/SubdomainFactory.gen"
import "test-utils"

fun parentSafetyRichBounceBody(originalBody: cell, originalValue: coins): cell {
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

fun inlineLinkedAction(action: uint8): RemainingBitsAndRefs {
    return beginCell()
        .storeBool(false)
        .storeAny(LinkedParentAction { action })
        .endCell()
        .beginParse();
}

fun referencedLinkedActionWithTrailingData(action: uint8): RemainingBitsAndRefs {
    return beginCell()
        .storeBool(true)
        .storeUint(1, 1)
        .storeRef(LinkedParentAction { action }.toCell())
        .endCell()
        .beginParse();
}

get fun `test v3 parent safety: standard inline Claim is accepted`() {
    val (collection, parent, _owner, _user) = deployLinkedCollection();
    val buyer = newActor("v3-inline-claim-buyer");

    val claim = collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 1001,
            oldOwnerAddress: buyer.address,
            payload: inlineLinkedAction(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: MIN_PARENT_RETURN_VALUE, bounce: false },
    );

    expect(claim).toHaveSuccessfulTx({ to: collection.address });
    expect(collection.getAdmin()).toEqual(buyer.address);
}

get fun `test v3 parent safety: malformed ref action cannot convert custody`() {
    val (collection, parent, owner, _user) = deployLinkedCollection();

    val malformed = collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 1002,
            oldOwnerAddress: owner.address,
            payload: referencedLinkedActionWithTrailingData(LINKED_ACTION_CONVERT_LOCKED),
        }.toCell(),
        { value: MIN_PARENT_RETURN_VALUE, bounce: false },
    );

    expect(malformed).toHaveSuccessfulTx({ to: collection.address });
    expect(collection.getIsLinked()).toEqual(true);
    expect(collection.getParentReturn().recipient).toEqual(owner.address);
}

get fun `test v3 parent safety: Linked retry is blocked while return is in flight`() {
    val (collection, parent, owner, user) = deployLinkedCollection();
    collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 1003,
            oldOwnerAddress: owner.address,
            payload: linkedActionPayload(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: MIN_PARENT_RETURN_VALUE, bounce: false },
    );

    val retry = collection.sendRetryParentReturn(
        user.address,
        1004,
        { value: MIN_PARENT_RETURN_VALUE, bounce: true },
    );
    expect(retry).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_PARENT_TRANSFER_IN_FLIGHT,
    });

    val pending = collection.getParentReturn();
    val failedReturn: TransferOwnership = {
        queryId: pending.returnQueryId,
        transferData: {
            newOwnerAddress: owner.address,
            responseDestination: collection.address,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: emptyTep62ForwardPayload(),
        },
    };
    testing.processSingleTraceStep(
        parent.address,
        createMessage({
            bounce: false,
            dest: collection.address,
            value: MIN_PARENT_RETURN_VALUE,
            body: parentSafetyRichBounceBody(
                failedReturn.toCell(),
                MIN_PARENT_RETURN_VALUE,
            ),
        }).bounced(),
    );
    expect(collection.getParentReturn().inFlight).toEqual(false);

    val afterBounce = collection.sendRetryParentReturn(
        user.address,
        1005,
        { value: MIN_PARENT_RETURN_VALUE, bounce: true },
    );
    expect(
        afterBounce.findTransaction<TransferOwnership>({
            from: collection.address,
            to: parent.address,
        }),
    ).toBeNotNull();
}

get fun `test v3 parent safety: Factory retry probes but never duplicates an in-flight handoff`() {
    val owner = newActor("v3-factory-inflight-owner");
    val parent = newActor("v3-factory-inflight-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val create = testing.processSingleTraceStep(
        parent.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: MIN_CREATE_VALUE,
            body: OwnershipAssigned {
                queryId: 1005,
                oldOwnerAddress: owner.address,
                payload: beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
            },
        }),
    );
    val collectionAddress = factory.getCollectionAddress(parent.address);
    val deployed = testing.processSingleTraceStep(
        factory.address,
        OutMessage { messageCell: create.outMessages.atCell(0) },
    );
    val handoff = testing.processSingleTraceStep(
        collectionAddress,
        OutMessage { messageCell: deployed.outMessages.atCell(0) },
    );
    expect(handoff.outMessages.size()).toEqual(1);
    val handoffMessage = handoff.outMessages.at<TransferOwnership>(0);
    expect(handoffMessage.info.dest).toEqual(parent.address);

    val retry = testing.processSingleTraceStep(
        owner.address,
        createMessage({
            bounce: true,
            dest: factory.address,
            value: ton("0.5"),
            body: RetryCollectionDeployment {
                queryId: 1006,
                collectionAddress,
            },
        }),
    );

    expect(retry.outMessages.size()).toEqual(2);
    expect(retry.outMessages.at<ConfirmParentHandoff>(0).info.dest).toEqual(collectionAddress);
    expect(retry.outMessages.at<Excesses>(1).info.dest).toEqual(owner.address);

    val bounced = createMessage({
        bounce: false,
        dest: factory.address,
        value: handoffMessage.info.value.grams,
        body: parentSafetyRichBounceBody(
            handoffMessage.loadBody().toCell(),
            handoffMessage.info.value.grams,
        ),
    }).bounced();
    testing.processSingleTraceStep(parent.address, bounced);

    val retryAfterBounce = testing.processSingleTraceStep(
        owner.address,
        createMessage({
            bounce: true,
            dest: factory.address,
            value: ton("0.5"),
            body: RetryCollectionDeployment {
                queryId: 1007,
                collectionAddress,
            },
        }),
    );
    expect(retryAfterBounce.outMessages.size()).toEqual(1);
    expect(retryAfterBounce.outMessages.at<TransferOwnership>(0).info.dest).toEqual(parent.address);

    val duplicate = factory.sendRetryCollectionDeployment(
        owner.address,
        1008,
        collectionAddress,
        { value: ton("0.5"), bounce: true },
    );
    expect(duplicate).toHaveSuccessfulTx({ to: factory.address });
    expect(
        duplicate.findTransaction<TransferOwnership>({ from: factory.address, to: parent.address }),
    ).toEqual(null);
}

get fun `test v3 parent safety: Factory return retry requires bounce and persists its lock`() {
    val owner = newActor("v3-factory-return-owner");
    val parent = newActor("v3-factory-return-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val create = testing.processSingleTraceStep(
        parent.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: MIN_CREATE_VALUE,
            body: OwnershipAssigned {
                queryId: 1100,
                oldOwnerAddress: owner.address,
                payload: beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
            },
        }),
    );
    val collectionAddress = factory.getCollectionAddress(parent.address);
    val lock = create.outMessages.at<LockCollection>(0);
    val failedDeploy = createMessage({
        bounce: false,
        dest: factory.address,
        value: COLLECTION_DEPLOY_VALUE,
        body: parentSafetyRichBounceBody(lock.loadBody().toCell(), COLLECTION_DEPLOY_VALUE),
    }).bounced();
    val recovery = testing.processSingleTraceStep(collectionAddress, failedDeploy);
    val firstReturn = recovery.outMessages.at<TransferOwnership>(0);

    val duplicateBeforeBounce = factory.sendRetryCollectionDeployment(
        owner.address,
        1101,
        collectionAddress,
        { value: ton("0.5"), bounce: true },
    );
    expect(duplicateBeforeBounce).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_PARENT_TRANSFER_IN_FLIGHT,
    });

    testing.processSingleTraceStep(
        parent.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: firstReturn.info.value.grams,
            body: parentSafetyRichBounceBody(
                firstReturn.loadBody().toCell(),
                firstReturn.info.value.grams,
            ),
        }).bounced(),
    );
    val retryAfterBounce = testing.processSingleTraceStep(
        owner.address,
        createMessage({
            bounce: true,
            dest: factory.address,
            value: ton("0.5"),
            body: RetryCollectionDeployment {
                queryId: 1102,
                collectionAddress,
            },
        }),
    );
    expect(retryAfterBounce.outMessages.size()).toEqual(1);
    expect(retryAfterBounce.outMessages.at<TransferOwnership>(0).info.dest).toEqual(parent.address);

    val duplicateAfterRetry = factory.sendRetryCollectionDeployment(
        owner.address,
        1103,
        collectionAddress,
        { value: ton("0.5"), bounce: true },
    );
    expect(duplicateAfterRetry).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_PARENT_TRANSFER_IN_FLIGHT,
    });
}

get fun `test v3 parent safety: Linked proof requires a previous owner`() {
    val (collection, parent, _owner, _user) = deployLinkedCollection();
    val missingOwner = collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 1200,
            oldOwnerAddress: null,
            payload: linkedActionPayload(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: MIN_PARENT_RETURN_VALUE, bounce: false },
    );
    expect(missingOwner).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_NULL_OLD_OWNER,
    });
}

get fun `test v3 parent safety: Factory handoff accepts inline and rejects malformed ref payloads`() {
    val (inlineCollection, inlineParent, inlineOwner, _user) = deployLockedCollection();
    val inlineMaster = inlineCollection.getLinkedAdmin();
    val inline = beginCell()
        .storeBool(false)
        .storeAny(
            FactoryHandoff {
                deploymentId: 1201,
                requestQueryId: 1202,
                intendedAdmin: inlineOwner.address,
            },
        )
        .endCell()
        .beginParse();
    val accepted = inlineCollection.sendAny(
        inlineParent.address,
        OwnershipAssigned {
            queryId: 1201,
            oldOwnerAddress: inlineMaster,
            payload: inline,
        }.toCell(),
        { value: ton("0.2"), bounce: false },
    );
    expect(
        accepted.findTransaction<ParentHandoffComplete>({
            from: inlineCollection.address,
            to: inlineMaster,
        }),
    ).toBeNotNull();

    val malformed = beginCell()
        .storeBool(true)
        .storeUint(1, 1)
        .storeRef(
            FactoryHandoff {
                deploymentId: 1203,
                requestQueryId: 1204,
                intendedAdmin: inlineOwner.address,
            }.toCell(),
        )
        .endCell()
        .beginParse();
    val rejected = inlineCollection.sendAny(
        inlineParent.address,
        OwnershipAssigned {
            queryId: 1203,
            oldOwnerAddress: inlineMaster,
            payload: malformed,
        }.toCell(),
        { value: ton("0.2"), bounce: false },
    );
    expect(
        rejected.findTransaction<ParentHandoffComplete>({ from: inlineCollection.address }),
    ).toEqual(null);
}

get fun `test v3 parent safety: Linked transfer bounces require exact active state`() {
    val master = newActor("v3-bounce-skeleton-master");
    val skeletonParent = newActor("v3-bounce-skeleton-parent");
    val skeletonOwner = newActor("v3-bounce-skeleton-owner");
    val skeleton = SubdomainCollection.fromStorage({
        master: master.address,
        parentDomain: skeletonParent.address,
        isLinked: true,
        linkedAdmin: skeletonOwner.address,
    });
    skeleton.deploy(master.address, { value: ton("0.1"), bounce: false });
    val skeletonReturn: TransferOwnership = {
        queryId: 1,
        transferData: {
            newOwnerAddress: skeletonOwner.address,
            responseDestination: skeleton.address,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: emptyTep62ForwardPayload(),
        },
    };
    val skeletonBounce = net.send(
        skeletonParent.address,
        createMessage({
            bounce: false,
            dest: skeleton.address,
            value: ton("0.01"),
            body: parentSafetyRichBounceBody(skeletonReturn.toCell(), ton("0.01")),
        }).bounced(),
    );
    expect(skeletonBounce).toHaveSuccessfulTx({ to: skeleton.address });

    val (collection, parent, owner, user) = deployLinkedCollection();
    val noPendingBounce = net.send(
        parent.address,
        createMessage({
            bounce: false,
            dest: collection.address,
            value: ton("0.01"),
            body: parentSafetyRichBounceBody(skeletonReturn.toCell(), ton("0.01")),
        }).bounced(),
    );
    expect(noPendingBounce).toHaveSuccessfulTx({ to: collection.address });
    expect(collection.getParentReturn().pending).toEqual(false);

    collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 1205,
            oldOwnerAddress: owner.address,
            payload: linkedActionPayload(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: MIN_PARENT_RETURN_VALUE, bounce: false },
    );
    val pending = collection.getParentReturn();
    val exactReturn: TransferOwnership = {
        queryId: pending.returnQueryId,
        transferData: {
            newOwnerAddress: owner.address,
            responseDestination: collection.address,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: emptyTep62ForwardPayload(),
        },
    };
    net.send(
        user.address,
        createMessage({
            bounce: false,
            dest: collection.address,
            value: ton("0.01"),
            body: parentSafetyRichBounceBody(exactReturn.toCell(), ton("0.01")),
        }).bounced(),
    );
    expect(collection.getParentReturn().inFlight).toEqual(true);

    var malformedPayload = exactReturn;
    malformedPayload.transferData.forwardPayload = beginCell()
        .storeBool(false)
        .storeBool(false)
        .endCell()
        .beginParse();
    net.send(
        parent.address,
        createMessage({
            bounce: false,
            dest: collection.address,
            value: ton("0.01"),
            body: parentSafetyRichBounceBody(malformedPayload.toCell(), ton("0.01")),
        }).bounced(),
    );
    expect(collection.getParentReturn().inFlight).toEqual(true);

    var wrongGeneration = exactReturn;
    wrongGeneration.queryId += 1;
    net.send(
        parent.address,
        createMessage({
            bounce: false,
            dest: collection.address,
            value: ton("0.01"),
            body: parentSafetyRichBounceBody(wrongGeneration.toCell(), ton("0.01")),
        }).bounced(),
    );
    expect(collection.getParentReturn().inFlight).toEqual(true);
}

get fun `test v3 parent safety: Locked return bounce requires its exact receipt`() {
    val (collection, parent, owner, _user) = deployLockedCollection();
    val master = collection.getLinkedAdmin();
    val intendedAdmin = newActor("v3-locked-return-intended-admin");
    val handoff: FactoryHandoff = {
        deploymentId: 1206,
        requestQueryId: 1207,
        intendedAdmin: intendedAdmin.address,
    };
    val returned: TransferOwnership = {
        queryId: handoff.deploymentId,
        transferData: {
            newOwnerAddress: handoff.intendedAdmin,
            responseDestination: master,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: beginCell()
                .storeBool(true)
                .storeRef(handoff.toCell())
                .endCell()
                .beginParse(),
        },
    };

    val withoutReceipt = net.send(
        parent.address,
        createMessage({
            bounce: false,
            dest: collection.address,
            value: ton("0.05"),
            body: parentSafetyRichBounceBody(returned.toCell(), ton("0.05")),
        }).bounced(),
    );
    expect(withoutReceipt).toHaveSuccessfulTx({ to: collection.address });

    collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: handoff.deploymentId,
            oldOwnerAddress: master,
            payload: beginCell().storeBool(true).storeRef(handoff.toCell()).endCell().beginParse(),
        }.toCell(),
        { value: ton("0.2"), bounce: false },
    );
    var mismatched = returned;
    mismatched.queryId += 1;
    net.send(
        parent.address,
        createMessage({
            bounce: false,
            dest: collection.address,
            value: ton("0.05"),
            body: parentSafetyRichBounceBody(mismatched.toCell(), ton("0.05")),
        }).bounced(),
    );
    val confirmation = collection.sendConfirmParentHandoff(
        master,
        handoff.deploymentId,
        handoff.requestQueryId,
        parent.address,
        intendedAdmin.address,
        { value: ton("0.1"), bounce: true },
    );
    expect(
        confirmation.findTransaction<TransferOwnership>({
            from: collection.address,
            to: parent.address,
        }),
    ).toEqual(null);
    expect(collection.getAdmin()).toEqual(owner.address);
}
