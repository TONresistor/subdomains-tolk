import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/errors"
import "@contracts/messages"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "@wrappers/SubdomainFactory.gen"
import "@wrappers/SubdomainItem.gen"
import "test-utils"

fun mutationRichBounce(originalBody: cell, originalValue: coins): cell {
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

fun forwardedFee(info: TlbCommonMessageInfo): coins {
    match (info) {
        TlbInternalMessage => return info.forwardFee,
        TlbExternalInMessageInfo => throw 0,
        TlbExternalOutMessageInfo => throw 0,
    }
}

fun messageValue(info: TlbCommonMessageInfo): coins {
    match (info) {
        TlbInternalMessage => return info.value.grams,
        TlbExternalInMessageInfo => throw 0,
        TlbExternalOutMessageInfo => throw 0,
    }
}

fun deployInitializedItem(owner: Treasury, label: string, value: coins): SubdomainItem {
    val now = blockchain.now();
    val records: DnsRecords = [];
    val storage: ItemStorageInitialized = {
        index: labelIndex(label),
        collectionAddress: owner.address,
        ownerAddress: owner.address,
        records: records.toCell(),
        label: labelSlice(label).toCell(),
        mintedAt: now,
        lastTouch: now,
        validUntil: 0,
    };
    val stateInit: ContractState = { code: build("SubdomainItem"), data: storage.toCell() };
    val item = SubdomainItem {
        address: AutoDeployAddress {
            workchain: BASECHAIN,
            stateInit,
        }.calculateAddress(),
        stateInit,
    };
    val deployment = item.deploy(owner.address, { value, bounce: false });
    expect(deployment).toHaveSuccessfulTx({ to: item.address });
    return item;
}

fun deployInitializedCollection(
    master: Treasury,
    parent: Treasury,
    admin: Treasury,
    origin: CollectionOrigin,
    minted: map<uint256, ()>,
    mintedCount: uint32,
    value: coins,
): SubdomainCollection {
    val reserved: map<uint256, ()> = [];
    val storage: CollectionStorage = {
        master: master.address,
        parentDomain: parent.address,
        admin: admin.address,
        origin: origin.toCell(),
        isLinked: false,
        lastParentFillUp: blockchain.now(),
        meta: makeMeta().toCell(),
        names: CollectionNames { reserved, minted, mintedCount }.toCell(),
        policy: CollectionPolicyState {
            accessMode: ACCESS_PUBLIC,
            withdrawableRevenue: 0,
            allowlist: [],
            pendingMints: [],
            parentGeneration: 0,
            pendingParentReturn: null,
        }.toCell(),
    };
    val stateInit: ContractState = { code: build("SubdomainCollection"), data: storage.toCell() };
    val collection = SubdomainCollection {
        address: AutoDeployAddress {
            workchain: BASECHAIN,
            stateInit,
        }.calculateAddress(),
        stateInit,
    };
    collection.deploy(master.address, { value, bounce: false });
    return collection;
}

get fun `test mutation: factory rejects a forged current-generation transfer bounce`() {
    val owner = newActor("mutation-bounce-owner");
    val attacker = newActor("mutation-bounce-attacker");
    val parent = newActor("mutation-bounce-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val create = createMessage({
        bounce: false,
        dest: factory.address,
        value: MIN_CREATE_VALUE,
        body: OwnershipAssigned {
            queryId: 100,
            oldOwnerAddress: owner.address,
            payload: beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        },
    });
    val createStep = testing.processSingleTraceStep(parent.address, create);
    val lock = createStep.outMessages.at<LockCollection>(0).loadBody();
    val forgedPayload = beginCell()
        .storeBool(true)
        .storeRef(
            FactoryHandoff {
                deploymentId: lock.deploymentId,
                requestQueryId: lock.queryId,
                intendedAdmin: attacker.address,
            }.toCell(),
        )
        .endCell()
        .beginParse();
    val forgedTransfer = TransferOwnership {
        queryId: lock.deploymentId,
        transferData: {
            newOwnerAddress: factory.getCollectionAddress(parent.address),
            responseDestination: owner.address,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: forgedPayload,
        },
    };
    val bounced = createMessage({
        bounce: false,
        dest: factory.address,
        value: ton("0.1"),
        body: mutationRichBounce(forgedTransfer.toCell(), ton("0.1")),
    }).bounced();
    val result = net.send(parent.address, bounced);

    expect(result).toHaveFailedTx({ to: factory.address, exitCode: ERROR_NOT_FROM_COLLECTION });
}

get fun `test mutation: rejected custody authenticates bounce, ack and retry`() {
    val owner = newActor("mutation-rejected-owner");
    val attacker = newActor("mutation-rejected-attacker");
    val parent = newActor("mutation-rejected-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val rejected = testing.processSingleTraceStep(
        parent.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("1"),
            body: OwnershipAssigned {
                queryId: 150,
                oldOwnerAddress: owner.address,
                payload: beginCell()
                    .storeRef(beginCell().storeUint(1, 1).endCell())
                    .endCell()
                    .beginParse(),
            },
        }),
    );
    val returned = rejected.outMessages.at<TransferOwnership>(0);
    val returnBody = returned.loadBody();

    var forgedCurrent = returnBody;
    forgedCurrent.transferData.forwardPayload = beginCell()
        .storeBool(true)
        .storeRef(
            FactoryHandoff {
                deploymentId: returnBody.queryId,
                requestQueryId: 150,
                intendedAdmin: attacker.address,
            }.toCell(),
        )
        .endCell()
        .beginParse();
    val forgedBounce = net.send(
        parent.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("0.1"),
            body: mutationRichBounce(forgedCurrent.toCell(), returned.info.value.grams),
        }).bounced(),
    );
    expect(forgedBounce).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    var oldGeneration = forgedCurrent;
    oldGeneration.transferData.forwardPayload = beginCell()
        .storeBool(true)
        .storeRef(
            FactoryHandoff {
                deploymentId: returnBody.queryId + 1,
                requestQueryId: 151,
                intendedAdmin: attacker.address,
            }.toCell(),
        )
        .endCell()
        .beginParse();
    val oldBounce = net.send(
        parent.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("0.1"),
            body: mutationRichBounce(oldGeneration.toCell(), returned.info.value.grams),
        }).bounced(),
    );
    expect(oldBounce).toHaveSuccessfulTx({ to: factory.address });
    expect(
        oldBounce.findTransaction<Excesses>({ from: factory.address, to: attacker.address }),
    ).toBeNotNull();

    val wrongAck = factory.sendAny(
        parent.address,
        Excesses { queryId: returnBody.queryId + 1 }.toCell(),
        { value: ton("0.01"), bounce: false },
    );
    expect(wrongAck).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    val collectionAddress = factory.getCollectionAddress(parent.address);
    val unauthorized = factory.sendRetryCollectionDeployment(
        attacker.address,
        152,
        collectionAddress,
        { value: ton("0.5"), bounce: true },
    );
    expect(unauthorized).toHaveFailedTx({ to: factory.address, exitCode: ERROR_NOT_ADMIN });

    val underfunded = factory.sendRetryCollectionDeployment(
        owner.address,
        153,
        collectionAddress,
        { value: ton("0.5") - 1, bounce: true },
    );
    expect(underfunded).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_INSUFFICIENT_BALANCE,
    });

    val retry = factory.sendRetryCollectionDeployment(
        owner.address,
        154,
        collectionAddress,
        { value: ton("0.5"), bounce: true },
    );
    expect(retry).toHaveSuccessfulTx({ to: factory.address });
    expect(
        retry.findTransaction<TransferOwnership>({ from: factory.address, to: parent.address }),
    ).toBeNotNull();
}

get fun `test mutation: factory authenticates recovery phase, generation and callback`() {
    val owner = newActor("mutation-recovery-owner");
    val attacker = newActor("mutation-recovery-attacker");
    val parent = newActor("mutation-recovery-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val create = createMessage({
        bounce: false,
        dest: factory.address,
        value: MIN_CREATE_VALUE,
        body: OwnershipAssigned {
            queryId: 200,
            oldOwnerAddress: owner.address,
            payload: beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        },
    });
    val createStep = testing.processSingleTraceStep(parent.address, create);
    val lockMessage = createStep.outMessages.at<LockCollection>(0);
    val lock = lockMessage.loadBody();
    val collectionAddress = factory.getCollectionAddress(parent.address);

    val prematureAck = factory.sendAny(
        parent.address,
        Excesses { queryId: lock.deploymentId }.toCell(),
        { value: ton("0.01"), bounce: false },
    );
    expect(prematureAck).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    val deployed = testing.processSingleTraceStep(
        factory.address,
        OutMessage { messageCell: createStep.outMessages.atCell(0) },
    );
    val readyMessage = deployed.outMessages.at<CollectionReady>(0);
    testing.processSingleTraceStep(
        collectionAddress,
        OutMessage { messageCell: deployed.outMessages.atCell(0) },
    );

    val wrongGenerationAck = factory.sendAny(
        parent.address,
        Excesses { queryId: lock.deploymentId + 1 }.toCell(),
        { value: ton("0.01"), bounce: false },
    );
    expect(wrongGenerationAck).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    val complete: ParentHandoffComplete = {
        deploymentId: lock.deploymentId,
        queryId: lock.queryId,
        parentDomain: parent.address,
        intendedAdmin: owner.address,
    };
    val wrongSender = factory.sendAny(
        attacker.address,
        complete.toCell(),
        { value: ton("0.01"), bounce: false },
    );
    expect(wrongSender).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    var wrongQuery = complete;
    wrongQuery.queryId += 1;
    val badQuery = factory.sendAny(
        collectionAddress,
        wrongQuery.toCell(),
        { value: ton("0.01"), bounce: false },
    );
    expect(badQuery).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    var wrongAdmin = complete;
    wrongAdmin.intendedAdmin = attacker.address;
    val badAdmin = factory.sendAny(
        collectionAddress,
        wrongAdmin.toCell(),
        { value: ton("0.01"), bounce: false },
    );
    expect(badAdmin).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });

    val underfundedRetry = factory.sendRetryCollectionDeployment(
        owner.address,
        201,
        collectionAddress,
        { value: ton("0.499999999"), bounce: true },
    );
    expect(underfundedRetry).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_INSUFFICIENT_BALANCE,
    });
    expect(readyMessage.loadBody().deploymentId).toEqual(lock.deploymentId);
}

get fun `test mutation: collection authenticates handoff proof and confirmation`() {
    val (collection, parent, owner, _user) = deployLockedCollection();
    val master = collection.getLinkedAdmin();
    val attacker = newActor("mutation-confirm-attacker");
    val otherParent = newActor("mutation-confirm-parent");
    val payload = beginCell()
        .storeBool(true)
        .storeRef(
            FactoryHandoff {
                deploymentId: 300,
                requestQueryId: 301,
                intendedAdmin: owner.address,
            }.toCell(),
        )
        .endCell()
        .beginParse();
    val mismatchedLanding = collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 302,
            oldOwnerAddress: master,
            payload,
        }.toCell(),
        { value: ton("0.2"), bounce: false },
    );
    expect(mismatchedLanding).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_NOT_FROM_MASTER,
    });

    val confirmation: ConfirmParentHandoff = {
        deploymentId: 300,
        queryId: 301,
        parentDomain: parent.address,
        intendedAdmin: owner.address,
    };
    val wrongSender = collection.sendAny(
        attacker.address,
        confirmation.toCell(),
        { value: ton("0.1"), bounce: true },
    );
    expect(wrongSender).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_NOT_FROM_MASTER,
    });

    var wrongParent = confirmation;
    wrongParent.parentDomain = otherParent.address;
    val badParent = collection.sendAny(
        master,
        wrongParent.toCell(),
        { value: ton("0.1"), bounce: true },
    );
    expect(badParent).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_NOT_FROM_MASTER,
    });
}

get fun `test mutation: item transfer reserves every required forward fee`() {
    val owner = newActor("mutation-fees-owner");
    val nextOwner = newActor("mutation-fees-next");
    val probe = deployInitializedItem(owner, "probe", ton("0.04"));
    val probeTransfer = probe.sendTransferOwnership(
        owner.address,
        400,
        makeTransferData(nextOwner.address, null, 0),
        { value: ton("0.02"), bounce: true },
    );
    val probeTx = probeTransfer.findTransaction<TransferOwnership>({ to: probe.address })!;
    val fee = forwardedFee(probeTx.loadInMsg<TransferOwnership>().info);

    val silent = deployInitializedItem(owner, "silent", ton("0.04"));
    expect(silent.getDomain().hash()).toEqual(labelSlice("silent").hash());
    val silentBalance = testing.getAccountBalance(silent.address);
    val boundaryValue = MIN_TONS_FOR_STORAGE - silentBalance + fee - 1;
    val boundaryTransfer = silent.sendTransferOwnership(
        owner.address,
        401,
        makeTransferData(nextOwner.address, null, 0),
        { value: boundaryValue, bounce: true },
    );
    expect(boundaryTransfer).toHaveSuccessfulTx({ to: silent.address });
    expect(silent.getEditor()).toEqual(nextOwner.address);

    val response = deployInitializedItem(owner, "response", ton("0.04"));
    val responseBalance = testing.getAccountBalance(response.address);
    val responseValue = ton("0.02");
    val responseTransfer = response.sendTransferOwnership(
        owner.address,
        402,
        makeTransferData(nextOwner.address, owner.address, 0),
        { value: responseValue, bounce: true },
    );
    val responseTx = responseTransfer.findTransaction<TransferOwnership>({ to: response.address })!;
    val responseFee = forwardedFee(responseTx.loadInMsg<TransferOwnership>().info);
    val excess = responseTransfer.findTransaction<Excesses>({
        from: response.address,
        to: owner.address,
    })!;
    val excessValue = messageValue(excess.loadInMsg<Excesses>().info);
    val maximum = responseBalance + responseValue - MIN_TONS_FOR_STORAGE - responseFee;
    expect(excessValue).toBeLessOrEqual(maximum);
    expect(excessValue).toBeGreater(maximum - responseFee);

    val forwarded = deployInitializedItem(owner, "forwarded", ton("0.04"));
    val forwardedBalance = testing.getAccountBalance(forwarded.address);
    val forwardedValue = ton("0.1");
    val forwardAmount = ton("0.01");
    val forwardedTransfer = forwarded.sendTransferOwnership(
        owner.address,
        403,
        makeTransferData(nextOwner.address, owner.address, forwardAmount),
        { value: forwardedValue, bounce: true },
    );
    val forwardedTx = forwardedTransfer.findTransaction<TransferOwnership>({
        to: forwarded.address,
    })!;
    val forwardedInputFee = forwardedFee(forwardedTx.loadInMsg<TransferOwnership>().info);
    val forwardedExcess = forwardedTransfer.findTransaction<Excesses>({
        from: forwarded.address,
        to: owner.address,
    })!;
    val forwardedExcessValue = messageValue(forwardedExcess.loadInMsg<Excesses>().info);
    val forwardedMaximum = forwardedBalance + forwardedValue - MIN_TONS_FOR_STORAGE -
    forwardAmount -
    forwardedInputFee * 2;
    expect(forwardedExcessValue).toBeLessOrEqual(forwardedMaximum);
}

get fun `test mutation: factory ignores malformed and unrelated bounces`() {
    val caller = newActor("mutation-malformed-caller");
    val nextOwner = newActor("mutation-malformed-owner");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(caller.address, { value: ton("1"), bounce: false });

    val truncated = net.send(
        caller.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("0.01"),
            body: beginCell().endCell(),
        }).bounced(),
    );
    expect(truncated).toHaveSuccessfulTx({ to: factory.address });

    val emptyOriginal = net.send(
        caller.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("0.01"),
            body: mutationRichBounce(beginCell().endCell(), ton("0.01")),
        }).bounced(),
    );
    expect(emptyOriginal).toHaveSuccessfulTx({ to: factory.address });

    val unknownOriginal = net.send(
        caller.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("0.01"),
            body: mutationRichBounce(
                beginCell().storeUint(0xdeadbeef, 32).endCell(),
                ton("0.01"),
            ),
        }).bounced(),
    );
    expect(unknownOriginal).toHaveSuccessfulTx({ to: factory.address });

    val invalidTransfer = TransferOwnership {
        queryId: 1,
        transferData: makeTransferData(nextOwner.address, null, 0),
    };
    val invalidPayload = net.send(
        caller.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("0.01"),
            body: mutationRichBounce(invalidTransfer.toCell(), ton("0.01")),
        }).bounced(),
    );
    expect(invalidPayload).toHaveSuccessfulTx({ to: factory.address });
}

get fun `test mutation: linked deployment bounce clears persisted recovery`() {
    val owner = newActor("mutation-linked-bounce-owner");
    val parent = newActor("mutation-linked-bounce-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val request = createMessage({
        bounce: true,
        dest: factory.address,
        value: ton("0.5"),
        body: CreateLinkedCollection {
            queryId: 500,
            parentDomain: parent.address,
            admin: owner.address,
            meta: makeMeta().toCell(),
        },
    });
    val createStep = testing.processSingleTraceStep(owner.address, request);
    val lock = createStep.outMessages.at<LockCollection>(0).loadBody();
    val collectionAddress = factory.getLinkedCollectionAddress(parent.address, owner.address);
    val bounced = net.send(
        collectionAddress,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("0.24"),
            body: mutationRichBounce(lock.toCell(), COLLECTION_DEPLOY_VALUE),
        }).bounced(),
    );
    expect(bounced).toHaveSuccessfulTx({ to: factory.address });
    expect(bounced.findTransaction<Excesses>({ from: factory.address })).toBeNotNull();
    expect(bounced.findTransaction<TransferOwnership>({ from: factory.address })).toEqual(null);

    val retry = factory.sendRetryCollectionDeployment(
        owner.address,
        501,
        collectionAddress,
        { value: ton("0.5"), bounce: true },
    );
    expect(retry).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });
}

get fun `test mutation: factory refunds linked create and retry values exactly`() {
    val owner = newActor("mutation-linked-refund-owner");
    val parentA = newActor("mutation-linked-refund-parent-a");
    val parentB = newActor("mutation-linked-refund-parent-b");
    val parentC = newActor("mutation-linked-refund-parent-c");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val createStep = testing.processSingleTraceStep(
        owner.address,
        createMessage({
            bounce: true,
            dest: factory.address,
            value: ton("0.5"),
            body: CreateLinkedCollection {
                queryId: 600,
                parentDomain: parentA.address,
                admin: owner.address,
                meta: makeMeta().toCell(),
            },
        }),
    );
    expect(createStep.outMessages.size()).toEqual(2);
    expect(createStep.outMessages.at<Excesses>(1).info.value.grams).toBeGreater(ton("0.239"));
    expect(createStep.outMessages.at<Excesses>(1).info.value.grams).toBeLessOrEqual(ton("0.24"));

    val exactPending = testing.processSingleTraceStep(
        owner.address,
        createMessage({
            bounce: true,
            dest: factory.address,
            value: ton("0.5"),
            body: CreateLinkedCollection {
                queryId: 601,
                parentDomain: parentB.address,
                admin: owner.address,
                meta: makeMeta().toCell(),
            },
        }),
    );
    expect(exactPending.outMessages.size()).toEqual(2);
    val exactRetry = testing.processSingleTraceStep(
        owner.address,
        createMessage({
            bounce: true,
            dest: factory.address,
            value: ton("0.26"),
            body: RetryCollectionDeployment {
                queryId: 602,
                collectionAddress: factory.getLinkedCollectionAddress(
                    parentB.address,
                    owner.address,
                ),
            },
        }),
    );
    expect(exactRetry.outMessages.size()).toEqual(1);
    val _exactDeploy = exactRetry.outMessages.at<LockCollection>(0);

    testing.processSingleTraceStep(
        owner.address,
        createMessage({
            bounce: true,
            dest: factory.address,
            value: ton("0.5"),
            body: CreateLinkedCollection {
                queryId: 603,
                parentDomain: parentC.address,
                admin: owner.address,
                meta: makeMeta().toCell(),
            },
        }),
    );
    val overpaidRetry = testing.processSingleTraceStep(
        owner.address,
        createMessage({
            bounce: true,
            dest: factory.address,
            value: ton("0.5"),
            body: RetryCollectionDeployment {
                queryId: 604,
                collectionAddress: factory.getLinkedCollectionAddress(
                    parentC.address,
                    owner.address,
                ),
            },
        }),
    );
    expect(overpaidRetry.outMessages.size()).toEqual(2);
    expect(overpaidRetry.outMessages.at<Excesses>(1).info.value.grams).toBeGreater(ton("0.239"));
    expect(overpaidRetry.outMessages.at<Excesses>(1).info.value.grams).toBeLessOrEqual(ton("0.24"));
}

get fun `test mutation: stale returned custody cannot revive an old deployment`() {
    val owner = newActor("mutation-stale-owner");
    val parent = newActor("mutation-stale-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val firstRequest = createMessage({
        bounce: false,
        dest: factory.address,
        value: MIN_CREATE_VALUE,
        body: OwnershipAssigned {
            queryId: 700,
            oldOwnerAddress: owner.address,
            payload: beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        },
    });
    val firstCreate = testing.processSingleTraceStep(parent.address, firstRequest);
    val firstLock = firstCreate.outMessages.at<LockCollection>(0).loadBody();
    val collectionAddress = factory.getCollectionAddress(parent.address);

    val firstBounce = testing.processSingleTraceStep(
        collectionAddress,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: COLLECTION_DEPLOY_VALUE,
            body: mutationRichBounce(firstLock.toCell(), COLLECTION_DEPLOY_VALUE),
        }).bounced(),
    );
    expect(firstBounce.outMessages.at<TransferOwnership>(0).info.dest).toEqual(parent.address);

    val secondRequest = createMessage({
        bounce: false,
        dest: factory.address,
        value: MIN_CREATE_VALUE,
        body: OwnershipAssigned {
            queryId: 701,
            oldOwnerAddress: owner.address,
            payload: beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        },
    });
    val secondCreate = testing.processSingleTraceStep(parent.address, secondRequest);
    val secondLock = secondCreate.outMessages.at<LockCollection>(0).loadBody();
    expect(secondLock.deploymentId == firstLock.deploymentId).toEqual(false);

    val lateFirstBounce = net.send(
        collectionAddress,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: COLLECTION_DEPLOY_VALUE,
            body: mutationRichBounce(firstLock.toCell(), COLLECTION_DEPLOY_VALUE),
        }).bounced(),
    );
    expect(lateFirstBounce).toHaveSuccessfulTx({ to: factory.address });
    expect(
        lateFirstBounce.findTransaction<Excesses>({
            from: factory.address,
            to: owner.address,
        }),
    ).toBeNotNull();
    expect(
        lateFirstBounce.findTransaction<TransferOwnership>({ from: factory.address }),
    ).toEqual(null);

    val secondBounce = testing.processSingleTraceStep(
        collectionAddress,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: COLLECTION_DEPLOY_VALUE,
            body: mutationRichBounce(secondLock.toCell(), COLLECTION_DEPLOY_VALUE),
        }).bounced(),
    );
    expect(secondBounce.outMessages.at<TransferOwnership>(0).info.dest).toEqual(parent.address);

    val rejected = testing.processSingleTraceStep(
        parent.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("1"),
            body: OwnershipAssigned {
                queryId: 702,
                oldOwnerAddress: owner.address,
                payload: beginCell()
                    .storeRef(beginCell().storeUint(1, 1).endCell())
                    .endCell()
                    .beginParse(),
            },
        }),
    );
    val rejectedReturn = rejected.outMessages.at<TransferOwnership>(0).loadBody();
    val acknowledgement = factory.sendAny(
        parent.address,
        Excesses { queryId: rejectedReturn.queryId }.toCell(),
        { value: ton("0.01"), bounce: false },
    );
    expect(acknowledgement).toHaveSuccessfulTx({ to: factory.address });

    val retry = factory.sendRetryCollectionDeployment(
        owner.address,
        703,
        collectionAddress,
        { value: ton("0.5"), bounce: true },
    );
    expect(retry).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_NOT_FROM_COLLECTION,
    });
}

get fun `test mutation: collection readiness cannot skip generation or phase`() {
    val owner = newActor("mutation-ready-owner");
    val parent = newActor("mutation-ready-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val request = createMessage({
        bounce: false,
        dest: factory.address,
        value: MIN_CREATE_VALUE,
        body: OwnershipAssigned {
            queryId: 800,
            oldOwnerAddress: owner.address,
            payload: beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        },
    });
    val createStep = testing.processSingleTraceStep(parent.address, request);
    val lock = createStep.outMessages.at<LockCollection>(0).loadBody();
    val collectionAddress = factory.getCollectionAddress(parent.address);
    val ready: CollectionReady = {
        deploymentId: lock.deploymentId,
        queryId: lock.queryId,
        parentDomain: parent.address,
        admin: owner.address,
        currentAdmin: owner.address,
        isLinked: false,
        isNew: true,
    };

    var oldReady = ready;
    oldReady.deploymentId += 1;
    val wrongGeneration = testing.processSingleTraceStep(
        collectionAddress,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("0.01"),
            body: oldReady,
        }),
    );
    expect(wrongGeneration.outMessages.size()).toEqual(1);
    expect(wrongGeneration.outMessages.at<Excesses>(0).loadBody().queryId).toEqual(800);

    val deployed = testing.processSingleTraceStep(
        factory.address,
        OutMessage { messageCell: createStep.outMessages.atCell(0) },
    );
    val validReady = deployed.outMessages.at<CollectionReady>(0);
    testing.processSingleTraceStep(
        collectionAddress,
        OutMessage { messageCell: deployed.outMessages.atCell(0) },
    );
    val duplicateReady = testing.processSingleTraceStep(
        collectionAddress,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: ton("0.01"),
            body: validReady.loadBody(),
        }),
    );
    expect(duplicateReady.outMessages.size()).toEqual(1);
    expect(duplicateReady.outMessages.at<Excesses>(0).loadBody().queryId).toEqual(800);
}

get fun `test mutation: handoff completion cannot skip generation or phase`() {
    val owner = newActor("mutation-complete-owner");
    val parentA = newActor("mutation-complete-parent-a");
    val parentB = newActor("mutation-complete-parent-b");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val requestA = createMessage({
        bounce: false,
        dest: factory.address,
        value: MIN_CREATE_VALUE,
        body: OwnershipAssigned {
            queryId: 900,
            oldOwnerAddress: owner.address,
            payload: beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        },
    });
    val createA = testing.processSingleTraceStep(parentA.address, requestA);
    val lockA = createA.outMessages.at<LockCollection>(0).loadBody();
    val collectionA = factory.getCollectionAddress(parentA.address);
    val deployedA = testing.processSingleTraceStep(
        factory.address,
        OutMessage { messageCell: createA.outMessages.atCell(0) },
    );
    testing.processSingleTraceStep(
        collectionA,
        OutMessage { messageCell: deployedA.outMessages.atCell(0) },
    );
    val wrongGeneration = factory.sendParentHandoffComplete(
        collectionA,
        lockA.deploymentId + 1,
        lockA.queryId,
        parentA.address,
        owner.address,
        { value: ton("0.01"), bounce: false },
    );
    expect(wrongGeneration).toHaveSuccessfulTx({ to: factory.address });
    val retryA = factory.sendRetryCollectionDeployment(
        owner.address,
        901,
        collectionA,
        { value: ton("0.499999999"), bounce: true },
    );
    expect(retryA).toHaveFailedTx({
        to: factory.address,
        exitCode: ERROR_INSUFFICIENT_BALANCE,
    });

    val requestB = createMessage({
        bounce: false,
        dest: factory.address,
        value: MIN_CREATE_VALUE,
        body: OwnershipAssigned {
            queryId: 902,
            oldOwnerAddress: owner.address,
            payload: beginCell().storeRef(makeMeta().toCell()).endCell().beginParse(),
        },
    });
    val createB = testing.processSingleTraceStep(parentB.address, requestB);
    val lockB = createB.outMessages.at<LockCollection>(0).loadBody();
    val collectionB = factory.getCollectionAddress(parentB.address);
    val prematureComplete = factory.sendParentHandoffComplete(
        collectionB,
        lockB.deploymentId,
        lockB.queryId,
        parentB.address,
        owner.address,
        { value: ton("0.01"), bounce: false },
    );
    expect(prematureComplete).toHaveSuccessfulTx({ to: factory.address });
    val retryB = testing.processSingleTraceStep(
        owner.address,
        createMessage({
            bounce: true,
            dest: factory.address,
            value: ton("0.26"),
            body: RetryCollectionDeployment {
                queryId: 903,
                collectionAddress: collectionB,
            },
        }),
    );
    expect(retryB.outMessages.size()).toEqual(1);
    expect(retryB.outMessages.at<LockCollection>(0).loadBody().queryId).toEqual(902);
}

get fun `test mutation: collection safely ignores malformed bounces and empty topups`() {
    val (collection, _parent, _owner, user) = deployLockedCollection();
    val malformed = net.send(
        user.address,
        createMessage({
            bounce: false,
            dest: collection.address,
            value: ton("0.01"),
            body: beginCell().endCell(),
        }).bounced(),
    );
    expect(malformed).toHaveSuccessfulTx({ to: collection.address });

    val emptyOriginal = net.send(
        user.address,
        createMessage({
            bounce: false,
            dest: collection.address,
            value: ton("0.01"),
            body: mutationRichBounce(beginCell().endCell(), ton("0.01")),
        }).bounced(),
    );
    expect(emptyOriginal).toHaveSuccessfulTx({ to: collection.address });

    val wrongOpcode = net.send(
        user.address,
        createMessage({
            bounce: false,
            dest: collection.address,
            value: ton("0.01"),
            body: mutationRichBounce(
                beginCell().storeUint(0xdeadbeef, 32).endCell(),
                ton("0.01"),
            ),
        }).bounced(),
    );
    expect(wrongOpcode).toHaveSuccessfulTx({ to: collection.address });

    val label = "unmintedlabel";
    val init: SubdomainInit = {
        queryId: 1000,
        index: labelIndex(label),
        minter: user.address,
        label: labelSlice(label).toCell(),
        setWalletToMinter: false,
        initialRecords: null,
    };
    val unminted = testing.processSingleTraceStep(
        collection.getNftAddressByIndex(labelIndex(label)),
        createMessage({
            bounce: false,
            dest: collection.address,
            value: ton("0.06"),
            body: mutationRichBounce(init.toCell(), ITEM_DEPLOY_COST),
        }).bounced(),
    );
    expect(unminted.outMessages.size()).toEqual(0);

    val activeTopup = collection.sendAny(
        user.address,
        beginCell().endCell(),
        { value: ton("0.05"), bounce: false },
    );
    expect(activeTopup).toHaveSuccessfulTx({ to: collection.address });
}

get fun `test mutation: skeleton guards and getters remain total`() {
    val master = newActor("mutation-skeleton-master");
    val parent = newActor("mutation-skeleton-parent");
    val user = newActor("mutation-skeleton-user");
    val skeleton = SubdomainCollection.fromStorage({
        master: master.address,
        parentDomain: parent.address,
        isLinked: false,
        linkedAdmin: master.address,
    });
    skeleton.deploy(master.address, { value: ton("0.1"), bounce: false });

    val topup = skeleton.sendAny(
        user.address,
        beginCell().endCell(),
        { value: ton("0.05"), bounce: false },
    );
    expect(topup).toHaveSuccessfulTx({ to: skeleton.address });
    val (_royaltyNumerator, _royaltyDenominator, royaltyDestination) = skeleton.royaltyParams();
    expect(royaltyDestination).toEqual(skeleton.address);
    expect(skeleton.getMinChars()).toEqual(0);
    expect(
        skeleton.getNftContent(1, beginCell().storeUint(1, 1).endCell()).beginParse().isEmpty(),
    ).toEqual(true);

    val label = "skeleton";
    val init: SubdomainInit = {
        queryId: 1001,
        index: labelIndex(label),
        minter: user.address,
        label: labelSlice(label).toCell(),
        setWalletToMinter: false,
        initialRecords: null,
    };
    val bounce = net.send(
        skeleton.getNftAddressByIndex(labelIndex(label)),
        createMessage({
            bounce: false,
            dest: skeleton.address,
            value: ton("0.06"),
            body: mutationRichBounce(init.toCell(), ITEM_DEPLOY_COST),
        }).bounced(),
    );
    expect(bounce).toHaveSuccessfulTx({ to: skeleton.address });
}

get fun `test mutation: collection saturates mint rollback and validates handoff encoding`() {
    val master = newActor("mutation-saturation-master");
    val parent = newActor("mutation-saturation-parent");
    val owner = newActor("mutation-saturation-owner");
    val minter = newActor("mutation-saturation-minter");
    val label = "saturated";
    var minted: map<uint256, ()> = [];
    minted.set(labelIndex(label), ());
    val origin: CollectionOrigin = {
        linkedAdmin: master.address,
        isLinkedAtDeployment: false,
        lastFactoryHandoff: null,
    };
    val collection = deployInitializedCollection(
        master,
        parent,
        owner,
        origin,
        minted,
        0,
        ton("2"),
    );
    val init: SubdomainInit = {
        queryId: 1002,
        index: labelIndex(label),
        minter: minter.address,
        label: labelSlice(label).toCell(),
        setWalletToMinter: false,
        initialRecords: null,
    };
    val rollback = net.send(
        collection.getNftAddressByIndex(labelIndex(label)),
        createMessage({
            bounce: false,
            dest: collection.address,
            value: ton("0.06"),
            body: mutationRichBounce(init.toCell(), ITEM_DEPLOY_COST),
        }).bounced(),
    );
    expect(rollback).toHaveSuccessfulTx({ to: collection.address });
    expect(collection.getMintedCount()).toEqual(0);

    val inlinePayload = beginCell().storeBool(true).endCell().beginParse();
    val landing = collection.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 1003,
            oldOwnerAddress: owner.address,
            payload: inlinePayload,
        }.toCell(),
        { value: ton("0.2"), bounce: false },
    );
    expect(landing).toHaveSuccessfulTx({ to: collection.address });
}

get fun `test mutation: collection withdrawal preserves the requested amount and floor`() {
    val (collection, _parent, owner, user) = deployLockedCollection();
    mintSubdomain(collection, user, "withdraw", ton("5"));
    val partial = collection.sendWithdrawFees(
        owner.address,
        1100,
        ton("0.01"),
        { value: ton("0.05"), bounce: true },
    );
    val payout = partial.findTransaction({ from: collection.address, to: owner.address })!;
    expect(messageValue(payout.loadInMsg<RemainingBitsAndRefs>().info)).toBeLessOrEqual(
        ton("0.01"),
    );

    val master = newActor("mutation-floor-master");
    val parent = newActor("mutation-floor-parent");
    val floorOwner = newActor("mutation-floor-owner");
    val minted: map<uint256, ()> = [];
    val origin: CollectionOrigin = {
        linkedAdmin: master.address,
        isLinkedAtDeployment: false,
        lastFactoryHandoff: null,
    };
    val floor = deployInitializedCollection(
        master,
        parent,
        floorOwner,
        origin,
        minted,
        0,
        COLLECTION_MIN_BALANCE + FWD_FEE_RESERVE,
    );
    val noPayout = floor.sendWithdrawFees(
        floorOwner.address,
        1101,
        0,
        { value: ton("0.05"), bounce: true },
    );
    expect(noPayout).toHaveSuccessfulTx({ to: floor.address });
    expect(noPayout.findTransaction({ from: floor.address, to: floorOwner.address })).toEqual(null);
}

get fun `test mutation: collection recovery receipt controls replay behavior`() {
    val master = newActor("mutation-receipt-master");
    val parent = newActor("mutation-receipt-parent");
    val owner = newActor("mutation-receipt-owner");
    val minted: map<uint256, ()> = [];
    val emptyOrigin: CollectionOrigin = {
        linkedAdmin: master.address,
        isLinkedAtDeployment: false,
        lastFactoryHandoff: null,
    };
    val empty = deployInitializedCollection(
        master,
        parent,
        owner,
        emptyOrigin,
        minted,
        0,
        ton("1"),
    );
    val noReceipt = empty.sendConfirmParentHandoff(
        master.address,
        1200,
        1201,
        parent.address,
        owner.address,
        { value: ton("0.1"), bounce: true },
    );
    expect(noReceipt).toHaveSuccessfulTx({ to: empty.address });
    expect(noReceipt.findTransaction({ from: empty.address })).toEqual(null);

    val receipt: FactoryHandoffReceipt = {
        deploymentId: 1202,
        requestQueryId: 1203,
        intendedAdmin: owner.address,
        returnRequired: true,
    };
    val returningOrigin: CollectionOrigin = {
        linkedAdmin: master.address,
        isLinkedAtDeployment: false,
        lastFactoryHandoff: receipt.toCell(),
    };
    val returning = deployInitializedCollection(
        master,
        parent,
        owner,
        returningOrigin,
        minted,
        0,
        ton("1"),
    );
    val replay = returning.sendConfirmParentHandoff(
        master.address,
        receipt.deploymentId,
        receipt.requestQueryId,
        parent.address,
        owner.address,
        { value: ton("0.1"), bounce: true },
    );
    expect(
        replay.findTransaction<TransferOwnership>({
            from: returning.address,
            to: parent.address,
        }),
    ).toBeNotNull();
    expect(
        replay.findTransaction<ParentHandoffComplete>({ from: returning.address }),
    ).toEqual(null);

    val completedReceipt: FactoryHandoffReceipt = {
        deploymentId: 1204,
        requestQueryId: 1205,
        intendedAdmin: owner.address,
        returnRequired: false,
    };
    val completedOrigin: CollectionOrigin = {
        linkedAdmin: master.address,
        isLinkedAtDeployment: false,
        lastFactoryHandoff: completedReceipt.toCell(),
    };
    val completed = deployInitializedCollection(
        master,
        parent,
        owner,
        completedOrigin,
        minted,
        0,
        ton("1"),
    );
    val mismatch = completed.sendConfirmParentHandoff(
        master.address,
        completedReceipt.deploymentId,
        completedReceipt.requestQueryId + 1,
        parent.address,
        owner.address,
        { value: ton("0.1"), bounce: true },
    );
    expect(mismatch).toHaveSuccessfulTx({ to: completed.address });
    expect(mismatch.findTransaction({ from: completed.address })).toEqual(null);
}
