import "errors"
import "messages"
import "metadata"
import "prices"
import "storage"
// Tier 0: global, free, permissionless, non-upgradeable.
// check-disable-next-line import-path-can-use-mappings
import "../gen/SubdomainCollection.code"

struct PendingDeployment {
    deploymentId: uint64
    parentDomain: address
    admin: address
    queryId: uint64
    handoffValue: coins
    isLinked: bool
    phase: uint2
    meta: Cell<CollectionMeta>
    inFlight: bool = false
}

struct FactoryPendingReturn {
    deploymentId: uint64
    parentDomain: address
    admin: address
    queryId: uint64
    inFlight: bool = false
}

fun PendingDeployment.toPendingReturn(self): FactoryPendingReturn {
    return {
        deploymentId: self.deploymentId,
        parentDomain: self.parentDomain,
        admin: self.admin,
        queryId: self.queryId,
        inFlight: self.inFlight,
    };
}

const PHASE_AWAITING_COLLECTION = 0
const PHASE_AWAITING_HANDOFF = 1
const PHASE_RETURNING_PARENT = 2

struct FactoryStorage {
    pending: map<uint256, Cell<PendingDeployment>>
    rejectedReturns: map<uint256, Cell<FactoryPendingReturn>> = []
}

fun FactoryStorage.load(): FactoryStorage {
    return FactoryStorage.fromCell(contract.getData());
}

fun FactoryStorage.save(self) {
    contract.setData(self.toCell());
}

contract SubdomainFactory {
    author: "tolk-subdomains"
    version: "5.0.0"
    description: "Global factory for permanent Locked and self-custody Linked subdomain collections."
    incomingMessages: AllowedFactoryMessage
    storage: FactoryStorage
}

type AllowedFactoryMessage =
    | OwnershipAssigned
    | CreateLinkedCollection
    | CollectionReady
    | ParentHandoffComplete
    | RetryCollectionDeployment

fun collectionKey(collectionAddress: address): uint256 {
    val (_, hash) = collectionAddress.getWorkchainAndHash();
    return hash;
}

fun sendPendingCollectionDeploy(pending: PendingDeployment, collectionCode: cell) {
    val deploy = createMessage({
        bounce: BounceMode.RichBounce,
        dest: calcDeployedCollection(
            contract.getAddress(),
            pending.parentDomain,
            pending.isLinked,
            pending.isLinked ? pending.admin : contract.getAddress(),
            collectionCode,
        ),
        value: COLLECTION_DEPLOY_VALUE,
        body: LockCollection {
            deploymentId: pending.deploymentId,
            queryId: pending.queryId,
            parentDomain: pending.parentDomain,
            admin: pending.admin,
            isLinked: pending.isLinked,
            meta: pending.meta,
        },
    });
    deploy.send(SEND_MODE_REGULAR);
}

fun sendParentTransfer(
    pending: FactoryPendingReturn,
    to: address,
    forwardAmount: coins,
    value: coins,
    responseDestination: address,
    sendMode: int = SEND_MODE_PAY_FEES_SEPARATELY,
) {
    val forwardPayload = beginCell()
        .storeBool(true)
        .storeRef(
            FactoryHandoff {
                deploymentId: pending.deploymentId,
                requestQueryId: pending.queryId,
                intendedAdmin: pending.admin,
            }.toCell(),
        )
        .endCell()
        .beginParse();
    val handoffMessage = createMessage({
        bounce: BounceMode.RichBounce,
        dest: pending.parentDomain,
        value,
        body: TransferOwnership {
            // Internal generation keeps retry acknowledgements unambiguous.
            queryId: pending.deploymentId,
            transferData: {
                newOwnerAddress: to,
                responseDestination,
                customPayload: null,
                forwardAmount,
                forwardPayload,
            },
        },
    });
    handoffMessage.send(sendMode);
}

fun matchesParentTransfer(
    transfer: TransferOwnership,
    pending: FactoryPendingReturn,
    newOwner: address,
    responseDestination: address,
    forwardAmount: coins,
): bool {
    val handoff = parseFactoryHandoffPayload(transfer.transferData.forwardPayload);
    if (handoff == null || transfer.transferData.responseDestination == null) {
        return false;
    }
    return transfer.queryId == pending.deploymentId &&
    transfer.transferData.newOwnerAddress == newOwner &&
    transfer.transferData.responseDestination! == responseDestination &&
    transfer.transferData.customPayload == null &&
    transfer.transferData.forwardAmount == forwardAmount &&
    handoff!.deploymentId == pending.deploymentId &&
    handoff!.requestQueryId == pending.queryId &&
    handoff!.intendedAdmin == pending.admin;
}

fun saveAndReturnRejectedParent(
    mutate st: FactoryStorage,
    key: uint256,
    parentDomain: address,
    admin: address,
    queryId: uint64,
    inValue: coins,
) {
    val canReturn = inValue >= MIN_REJECTED_RETURN_VALUE;
    val pending: FactoryPendingReturn = {
        deploymentId: blockchain.logicalTime(),
        parentDomain,
        admin,
        queryId,
        inFlight: canReturn,
    };
    st.rejectedReturns.set(key, pending.toCell());
    st.save();
    if (canReturn) {
        sendParentTransfer(
            pending,
            admin,
            0,
            inValue - FACTORY_GAS_MARGIN,
            contract.getAddress(),
        );
    }
}

fun completeDeployment(mutate st: FactoryStorage, key: uint256) {
    st.pending.delete(key);
    st.save();
}

fun refundRemainingMessageValue(to: address, queryId: uint64) {
    val refund = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value: 0,
        body: Excesses { queryId },
    });
    refund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

fun requestParentHandoffConfirmation(
    pending: PendingDeployment,
    collectionAddress: address,
) {
    val confirmation = createMessage({
        bounce: BounceMode.NoBounce,
        dest: collectionAddress,
        value: HANDOFF_CONFIRM_VALUE,
        body: ConfirmParentHandoff {
            deploymentId: pending.deploymentId,
            queryId: pending.queryId,
            parentDomain: pending.parentDomain,
            intendedAdmin: pending.admin,
        },
    });
    confirmation.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

// Rich bounces preserve recovery state until custody or return is acknowledged.
fun onBouncedMessage(in: InMessageBounced) {
    if (in.bouncedBody.remainingBitsCount() < 32 || in.bouncedBody.preloadUint(32) != 0xfffffffe) {
        return;
    }
    val rich = lazy RichBounceBody.fromSlice(in.bouncedBody);
    val originalBody = rich.originalBody.beginParse();
    if (originalBody.remainingBitsCount() < 32) {
        return;
    }
    val originalOpcode = originalBody.preloadUint(32);

    if (originalOpcode == 0x6c0c4b17) {
        val lock = lazy LockCollection.fromSlice(originalBody);
        val collectionCode = subdomainCollectionCompiledCode();
        val expected = calcDeployedCollection(
            contract.getAddress(),
            lock.parentDomain,
            lock.isLinked,
            lock.isLinked ? lock.admin : contract.getAddress(),
            collectionCode,
        ).calculateAddress();
        assert (in.senderAddress == expected) throw ERROR_NOT_FROM_COLLECTION;

        var st = lazy FactoryStorage.load();
        val key = collectionKey(expected);
        if (!st.pending.exists(key)) {
            // Authenticated value from a completed deployment attempt.
            val lateRefund = createMessage({
                bounce: BounceMode.NoBounce,
                dest: lock.admin,
                value: 0,
                body: Excesses { queryId: lock.queryId },
            });
            lateRefund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
            return;
        }
        var pending = st.pending.mustGet(key).load();
        if (pending.deploymentId != lock.deploymentId) {
            val oldGenerationRefund = createMessage({
                bounce: BounceMode.NoBounce,
                dest: lock.admin,
                value: 0,
                body: Excesses { queryId: lock.queryId },
            });
            oldGenerationRefund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
            return;
        }
        assert (pending.admin == lock.admin) throw ERROR_NOT_FROM_COLLECTION;
        assert (pending.queryId == lock.queryId) throw ERROR_NOT_FROM_COLLECTION;
        assert (pending.meta.hash() == lock.meta.hash()) throw ERROR_NOT_FROM_COLLECTION;
        // Readiness is terminal for the deployment phase.
        if (pending.phase != PHASE_AWAITING_COLLECTION) {
            val lateRefund = createMessage({
                bounce: BounceMode.NoBounce,
                dest: pending.admin,
                value: 0,
                body: Excesses { queryId: pending.queryId },
            });
            lateRefund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
            return;
        }

        if (pending.isLinked) {
            st.pending.delete(key);
            st.save();
            val refund = createMessage({
                bounce: BounceMode.NoBounce,
                dest: pending.admin,
                value: 0,
                body: Excesses { queryId: pending.queryId },
            });
            refund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
            return;
        }

        // Keep recovery state until the parent confirms return.
        pending.phase = PHASE_RETURNING_PARENT;
        pending.inFlight = true;
        st.pending.set(key, pending.toCell());
        st.save();
        sendParentTransfer(
            pending.toPendingReturn(),
            pending.admin,
            0,
            pending.handoffValue + in.valueCoins,
            contract.getAddress(),
        );
        return;
    }

    if (originalOpcode == 0x5fcc3d14) {
        var parsed: TransferOwnership? = null;
        try {
            parsed = TransferOwnership.fromSlice(originalBody);
        } catch {
            return;
        }
        val transfer = parsed!;
        val expectedCollection = calcDeployedCollection(
            contract.getAddress(),
            in.senderAddress,
            false,
            contract.getAddress(),
            subdomainCollectionCompiledCode(),
        ).calculateAddress();
        val key = collectionKey(expectedCollection);
        var st = lazy FactoryStorage.load();
        var matched = false;
        var refundAdmin: address? = null;
        var refundQueryId: uint64 = 0;
        if (st.pending.exists(key)) {
            var pending = st.pending.mustGet(key).load();
            var expectedOwner = pending.admin;
            var expectedResponse = contract.getAddress();
            var expectedForward: coins = 0;
            if (pending.phase == PHASE_AWAITING_HANDOFF) {
                expectedOwner = expectedCollection;
                expectedResponse = pending.admin;
                expectedForward = RESOLVER_PIN_FUND;
            }
            if (
                pending.inFlight &&
                (pending.phase == PHASE_AWAITING_HANDOFF ||
                pending.phase == PHASE_RETURNING_PARENT) &&
                pending.parentDomain == in.senderAddress &&
                matchesParentTransfer(
                    transfer,
                    pending.toPendingReturn(),
                    expectedOwner,
                    expectedResponse,
                    expectedForward,
                )
            ) {
                pending.inFlight = false;
                st.pending.set(key, pending.toCell());
                matched = true;
                refundAdmin = pending.admin;
                refundQueryId = pending.queryId;
            }
        }
        if (!matched && st.rejectedReturns.exists(key)) {
            var pending = st.rejectedReturns.mustGet(key).load();
            if (
                pending.inFlight && pending.parentDomain == in.senderAddress &&
                matchesParentTransfer(
                    transfer,
                    pending,
                    pending.admin,
                    contract.getAddress(),
                    0,
                )
            ) {
                pending.inFlight = false;
                st.rejectedReturns.set(key, pending.toCell());
                matched = true;
                refundAdmin = pending.admin;
                refundQueryId = pending.queryId;
            }
        }
        if (!matched) {
            return;
        }
        st.save();

        val refund = createMessage({
            bounce: BounceMode.NoBounce,
            dest: refundAdmin!,
            value: 0,
            body: Excesses { queryId: refundQueryId },
        });
        refund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
    }
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }

    if (in.body.remainingBitsCount() >= 32 && in.body.preloadUint(32) == 0xd53276db) {
        val acknowledgement = lazy Excesses.fromSlice(in.body);
        val expectedCollection = calcDeployedCollection(
            contract.getAddress(),
            in.senderAddress,
            false,
            contract.getAddress(),
            subdomainCollectionCompiledCode(),
        ).calculateAddress();
        val key = collectionKey(expectedCollection);
        var st = lazy FactoryStorage.load();
        if (st.rejectedReturns.exists(key)) {
            val pending = st.rejectedReturns.mustGet(key).load();
            assert (
                pending.inFlight && pending.deploymentId == acknowledgement.queryId
            ) throw ERROR_NOT_FROM_COLLECTION;
            st.rejectedReturns.delete(key);
            st.save();
            refundRemainingMessageValue(pending.admin, pending.queryId);
            return;
        }
        if (!st.pending.exists(key)) {
            return;
        }
        val pending = st.pending.mustGet(key).load();
        assert (pending.parentDomain == in.senderAddress) throw ERROR_NOT_FROM_COLLECTION;
        // AWAITING_HANDOFF also covers the collection's TransferAdmin race return.
        assert (
            pending.phase == PHASE_RETURNING_PARENT || pending.phase == PHASE_AWAITING_HANDOFF
        ) throw ERROR_NOT_FROM_COLLECTION;
        assert (pending.inFlight) throw ERROR_NOT_FROM_COLLECTION;
        assert (pending.deploymentId == acknowledgement.queryId) throw ERROR_NOT_FROM_COLLECTION;
        st.pending.delete(key);
        st.save();
        // The factory has no withdrawal path; forward the returned excess.
        val refund = createMessage({
            bounce: BounceMode.NoBounce,
            dest: pending.admin,
            value: 0,
            body: Excesses { queryId: pending.queryId },
        });
        refund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        return;
    }

    val msg = lazy AllowedFactoryMessage.fromSlice(
        in.body,
        { throwIfOpcodeDoesNotMatch: ERROR_UNKNOWN_OP },
    );

    match (msg) {
        OwnershipAssigned => {
            val parentDomain = in.senderAddress;
            assert (msg.oldOwnerAddress != null) throw ERROR_NULL_OLD_OWNER;
            val admin = msg.oldOwnerAddress!;
            // Validate before dispatch; later failure could strand transferred custody.
            val adminBasechain = admin.getWorkchain() == BASECHAIN;
            val parentBasechain = parentDomain.getWorkchain() == BASECHAIN;

            var payload = msg.payload;
            var metaCell = beginCell().endCell();
            var metaValid = false;
            if (payload.remainingRefsCount() > 0) {
                metaCell = payload.loadRef();
                try {
                    val parsed = CollectionMeta.fromCell(metaCell);
                    metaValid = parsed.priceConfig.load().isValid();
                    if (metaValid) {
                        assertOnchainMetadata(parsed.collectionContent);
                    }
                } catch {
                    metaValid = false;
                }
            }

            val collectionCode = subdomainCollectionCompiledCode();
            val collAddr = calcDeployedCollection(
                contract.getAddress(),
                parentDomain,
                false,                 // born-Locked: custodial address space
                contract.getAddress(), // deterministic sentinel; no user is bound in Locked mode
                collectionCode,
            ).calculateAddress();

            var st = lazy FactoryStorage.load();
            val pendingKey = collectionKey(collAddr);
            if (st.pending.exists(pendingKey)) {
                st.pending.delete(pendingKey);
            }
            // A new authenticated transfer proves an older rejected return completed.
            st.rejectedReturns.delete(pendingKey);

            if (
                in.valueCoins < MIN_CREATE_VALUE || !metaValid || !adminBasechain ||
                !parentBasechain
            ) {
                saveAndReturnRejectedParent(
                    mutate st,
                    pendingKey,
                    parentDomain,
                    admin,
                    msg.queryId,
                    in.valueCoins,
                );
                return;
            }
            val pending: PendingDeployment = {
                deploymentId: blockchain.logicalTime(),
                parentDomain,
                admin,
                queryId: msg.queryId,
                handoffValue: in.valueCoins - COLLECTION_DEPLOY_VALUE - FACTORY_GAS_MARGIN,
                isLinked: false,
                phase: PHASE_AWAITING_COLLECTION,
                meta: metaCell as Cell<CollectionMeta>,
                inFlight: false,
            };
            st.pending.set(pendingKey, pending.toCell());
            st.save();
            sendPendingCollectionDeploy(pending, collectionCode);
        }

        // Linked create has no parent custody.
        CreateLinkedCollection => {
            // A Linked collection is inert until the real parent owner connects next_resolver.
            assert (msg.admin.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            assert (msg.parentDomain.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
            // Bind the deterministic address and config to its creator.
            assert (msg.admin == in.senderAddress) throw ERROR_NOT_ADMIN;

            val meta = msg.meta.load();
            assert (meta.priceConfig.load().isValid()) throw ERROR_UNKNOWN_OP;
            assertOnchainMetadata(meta.collectionContent);
            assert (
                in.valueCoins >= COLLECTION_DEPLOY_VALUE + FACTORY_GAS_MARGIN
            ) throw ERROR_INSUFFICIENT_BALANCE;

            // The owner links the parent after deployment.
            val collectionCode = subdomainCollectionCompiledCode();
            val linkedDeployAddress = calcDeployedCollection(
                contract.getAddress(),
                msg.parentDomain,
                true,
                msg.admin,
                collectionCode,
            );
            var st = lazy FactoryStorage.load();
            val pendingKey = collectionKey(linkedDeployAddress.calculateAddress());
            var pending: PendingDeployment;
            if (st.pending.exists(pendingKey)) {
                // Stored parameters remain authoritative across retries.
                pending = st.pending.mustGet(pendingKey).load();
                assert (pending.meta.hash() == msg.meta.hash()) throw ERROR_UNKNOWN_OP;
            } else {
                pending = PendingDeployment {
                    deploymentId: blockchain.logicalTime(),
                    parentDomain: msg.parentDomain,
                    admin: msg.admin,
                    queryId: msg.queryId,
                    handoffValue: 0,
                    isLinked: true,
                    phase: PHASE_AWAITING_COLLECTION,
                    meta: msg.meta,
                    inFlight: false,
                };
                st.pending.set(pendingKey, pending.toCell());
                st.save();
            }
            sendPendingCollectionDeploy(pending, collectionCode);

            // Refund overpayment; the factory has no withdrawal path.
            val refund = in.valueCoins - COLLECTION_DEPLOY_VALUE - FACTORY_GAS_MARGIN;
            if (refund > 0) {
                val excessRefund = createMessage({
                    bounce: false,
                    dest: in.senderAddress,
                    value: refund,
                    body: Excesses { queryId: msg.queryId },
                });
                excessRefund.send(SEND_MODE_REGULAR);
            }
        }

        CollectionReady => {
            val collectionCode = subdomainCollectionCompiledCode();
            val expected = calcDeployedCollection(
                contract.getAddress(),
                msg.parentDomain,
                msg.isLinked,
                msg.isLinked ? msg.admin : contract.getAddress(),
                collectionCode,
            ).calculateAddress();
            assert (in.senderAddress == expected) throw ERROR_NOT_FROM_COLLECTION;

            var st = lazy FactoryStorage.load();
            val key = collectionKey(expected);
            if (!st.pending.exists(key)) {
                refundRemainingMessageValue(msg.admin, msg.queryId);
                return;
            }
            var pending = st.pending.mustGet(key).load();
            if (pending.deploymentId != msg.deploymentId) {
                refundRemainingMessageValue(msg.admin, msg.queryId);
                return;
            }
            assert (pending.admin == msg.admin) throw ERROR_NOT_FROM_COLLECTION;
            assert (pending.queryId == msg.queryId) throw ERROR_NOT_FROM_COLLECTION;
            if (pending.phase != PHASE_AWAITING_COLLECTION) {
                refundRemainingMessageValue(pending.admin, pending.queryId);
                return;
            }

            if (pending.isLinked) {
                completeDeployment(mutate st, key);
                refundRemainingMessageValue(pending.admin, pending.queryId);
                return;
            }

            if (msg.currentAdmin != pending.admin) {
                // After re-auction, return the parent without routing through the old registry.
                pending.phase = PHASE_RETURNING_PARENT;
                pending.inFlight = true;
                st.pending.set(key, pending.toCell());
                st.save();
                sendParentTransfer(
                    pending.toPendingReturn(),
                    pending.admin,
                    0,
                    pending.handoffValue,
                    contract.getAddress(),
                );
                return;
            }

            pending.phase = PHASE_AWAITING_HANDOFF;
            pending.inFlight = true;
            st.pending.set(key, pending.toCell());
            st.save();
            sendParentTransfer(
                pending.toPendingReturn(),
                expected,
                RESOLVER_PIN_FUND,
                pending.handoffValue,
                pending.admin,
            );
        }

        ParentHandoffComplete => {
            val expected = calcDeployedCollection(
                contract.getAddress(),
                msg.parentDomain,
                false,
                contract.getAddress(),
                subdomainCollectionCompiledCode(),
            ).calculateAddress();
            assert (in.senderAddress == expected) throw ERROR_NOT_FROM_COLLECTION;

            var st = lazy FactoryStorage.load();
            val key = collectionKey(expected);
            if (!st.pending.exists(key)) {
                refundRemainingMessageValue(msg.intendedAdmin, msg.queryId);
                return;
            }
            val pending = st.pending.mustGet(key).load();
            if (pending.deploymentId != msg.deploymentId) {
                refundRemainingMessageValue(msg.intendedAdmin, msg.queryId);
                return;
            }
            if (pending.phase != PHASE_AWAITING_HANDOFF) {
                refundRemainingMessageValue(pending.admin, pending.queryId);
                return;
            }
            assert (pending.queryId == msg.queryId) throw ERROR_NOT_FROM_COLLECTION;
            assert (pending.parentDomain == msg.parentDomain) throw ERROR_NOT_FROM_COLLECTION;
            assert (pending.admin == msg.intendedAdmin) throw ERROR_NOT_FROM_COLLECTION;
            assert (pending.inFlight) throw ERROR_NOT_FROM_COLLECTION;
            completeDeployment(mutate st, key);
            refundRemainingMessageValue(pending.admin, pending.queryId);
        }

        RetryCollectionDeployment => {
            var st = lazy FactoryStorage.load();
            val key = collectionKey(msg.collectionAddress);
            if (st.rejectedReturns.exists(key)) {
                var pending = st.rejectedReturns.mustGet(key).load();
                assert (in.senderAddress == pending.admin) throw ERROR_NOT_ADMIN;
                assert (in.valueCoins >= HANDOFF_RETRY_VALUE) throw ERROR_INSUFFICIENT_BALANCE;
                assert (!pending.inFlight) throw ERROR_PARENT_TRANSFER_IN_FLIGHT;
                pending.inFlight = true;
                st.rejectedReturns.set(key, pending.toCell());
                st.save();
                sendParentTransfer(
                    pending,
                    pending.admin,
                    0,
                    in.valueCoins - FACTORY_GAS_MARGIN,
                    contract.getAddress(),
                );
                return;
            }
            assert (st.pending.exists(key)) throw ERROR_NOT_FROM_COLLECTION;
            var pending = st.pending.mustGet(key).load();
            assert (in.senderAddress == pending.admin) throw ERROR_NOT_ADMIN;

            val collectionCode = subdomainCollectionCompiledCode();
            val expected = calcDeployedCollection(
                contract.getAddress(),
                pending.parentDomain,
                pending.isLinked,
                pending.isLinked ? pending.admin : contract.getAddress(),
                collectionCode,
            ).calculateAddress();
            assert (msg.collectionAddress == expected) throw ERROR_NOT_FROM_COLLECTION;

            if (pending.phase == PHASE_AWAITING_COLLECTION) {
                assert (
                    in.valueCoins >= COLLECTION_DEPLOY_VALUE + FACTORY_GAS_MARGIN
                ) throw ERROR_INSUFFICIENT_BALANCE;
                sendPendingCollectionDeploy(pending, collectionCode);

                val refund = in.valueCoins - COLLECTION_DEPLOY_VALUE - FACTORY_GAS_MARGIN;
                if (refund > 0) {
                    val excess = createMessage({
                        bounce: BounceMode.NoBounce,
                        dest: pending.admin,
                        value: refund,
                        body: Excesses { queryId: msg.queryId },
                    });
                    excess.send(SEND_MODE_REGULAR);
                }
                return;
            }

            assert (in.valueCoins >= HANDOFF_RETRY_VALUE) throw ERROR_INSUFFICIENT_BALANCE;
            if (pending.phase == PHASE_AWAITING_HANDOFF) {
                if (pending.inFlight) {
                    requestParentHandoffConfirmation(pending, expected);
                    refundRemainingMessageValue(pending.admin, msg.queryId);
                    return;
                }
                pending.inFlight = true;
                st.pending.set(key, pending.toCell());
                st.save();
                sendParentTransfer(
                    pending.toPendingReturn(),
                    expected,
                    RESOLVER_PIN_FUND,
                    in.valueCoins - FACTORY_GAS_MARGIN,
                    pending.admin,
                );
                return;
            }

            assert (pending.phase == PHASE_RETURNING_PARENT) throw ERROR_NOT_FROM_COLLECTION;
            assert (!pending.inFlight) throw ERROR_PARENT_TRANSFER_IN_FLIGHT;
            pending.inFlight = true;
            st.pending.set(key, pending.toCell());
            st.save();
            sendParentTransfer(
                pending.toPendingReturn(),
                pending.admin,
                0,
                in.valueCoins - FACTORY_GAS_MARGIN,
                contract.getAddress(),
            );
        }

        else => throw ERROR_UNKNOWN_OP,
    }
}

// Custodial collection address.
get fun get_collection_address(parentDomain: address): address {
    return calcDeployedCollection(
        contract.getAddress(),
        parentDomain,
        false,
        contract.getAddress(),
        subdomainCollectionCompiledCode(),
    ).calculateAddress();
}

// Creator-bound self-custody collection address.
get fun get_linked_collection_address(parentDomain: address, admin: address): address {
    return calcDeployedCollection(
        contract.getAddress(),
        parentDomain,
        true,
        admin,
        subdomainCollectionCompiledCode(),
    ).calculateAddress();
}
