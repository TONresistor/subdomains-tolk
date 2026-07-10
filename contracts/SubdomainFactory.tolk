import "errors"
import "messages"
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
}

const PHASE_AWAITING_COLLECTION = 0
const PHASE_AWAITING_HANDOFF = 1
const PHASE_RETURNING_PARENT = 2
const HANDOFF_RETRY_VALUE = ton("0.5")
const HANDOFF_CONFIRM_VALUE = ton("0.1")

struct FactoryStorage {
    deployedCount: uint64
    pending: map<uint256, Cell<PendingDeployment>>
    deployed: map<uint256, ()>
}

fun FactoryStorage.load(): FactoryStorage {
    return FactoryStorage.fromCell(contract.getData());
}

fun FactoryStorage.save(self) {
    contract.setData(self.toCell());
}

contract SubdomainFactory {
    author: "tolk-subdomains"
    version: "2.0.0"
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
    pending: PendingDeployment,
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

// Persist rejected custody before attempting a return that may be underfunded.
fun saveAndReturnRejectedParent(
    mutate st: FactoryStorage,
    key: uint256,
    parentDomain: address,
    admin: address,
    queryId: uint64,
    metaCell: cell,
) {
    val pending: PendingDeployment = {
        deploymentId: blockchain.logicalTime(),
        parentDomain,
        admin,
        queryId,
        handoffValue: 0,
        isLinked: false,
        phase: PHASE_RETURNING_PARENT,
        // Metadata is opaque in RETURNING_PARENT.
        meta: metaCell as Cell<CollectionMeta>,
    };
    st.pending.set(key, pending.toCell());
    st.save();
    sendParentTransfer(
        pending,
        admin,
        0,
        0,
        contract.getAddress(),
        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
    );
}

fun recordCompletedDeployment(mutate st: FactoryStorage, key: uint256) {
    st.pending.delete(key);
    if (!st.deployed.exists(key)) {
        st.deployed.set(key, ());
        st.deployedCount += 1;
    }
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
            // Authenticated value from a completed or superseded deploy attempt.
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
        st.pending.set(key, pending.toCell());
        st.save();
        sendParentTransfer(
            pending,
            pending.admin,
            0,
            pending.handoffValue + in.valueCoins,
            contract.getAddress(),
        );
        return;
    }

    if (originalOpcode == 0x5fcc3d14) {
        val transfer = lazy TransferOwnership.fromSlice(originalBody);
        var payload = transfer.transferData.forwardPayload;
        if (
            payload.remainingBitsCount() < 1 || !payload.loadBool() ||
            payload.remainingRefsCount() <
            1
        ) {
            return;
        }
        val handoff = FactoryHandoff.fromCell(payload.loadRef());
        val expectedCollection = calcDeployedCollection(
            contract.getAddress(),
            in.senderAddress,
            false,
            contract.getAddress(),
            subdomainCollectionCompiledCode(),
        ).calculateAddress();
        val key = collectionKey(expectedCollection);
        val st = lazy FactoryStorage.load();
        if (st.pending.exists(key)) {
            val pending = st.pending.mustGet(key).load();
            // Never let an older generation mutate current pending state.
            if (pending.deploymentId == handoff.deploymentId) {
                assert (pending.parentDomain == in.senderAddress) throw ERROR_NOT_FROM_COLLECTION;
                assert (pending.admin == handoff.intendedAdmin) throw ERROR_NOT_FROM_COLLECTION;
            }
        }

        // Refund this attempt; pending remains retryable.
        val refund = createMessage({
            bounce: BounceMode.NoBounce,
            dest: handoff.intendedAdmin,
            value: 0,
            body: Excesses { queryId: handoff.requestQueryId },
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
        if (!st.pending.exists(key)) {
            return;
        }
        val pending = st.pending.mustGet(key).load();
        assert (pending.parentDomain == in.senderAddress) throw ERROR_NOT_FROM_COLLECTION;
        // AWAITING_HANDOFF also covers the collection's TransferAdmin race return.
        assert (
            pending.phase == PHASE_RETURNING_PARENT || pending.phase == PHASE_AWAITING_HANDOFF
        ) throw ERROR_NOT_FROM_COLLECTION;
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
                    val grid = parsed.priceConfig.load();
                    metaValid = grid.isValid();
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
            // Preserve the existing generation on duplicate notification.
            if (st.pending.exists(pendingKey)) {
                refundRemainingMessageValue(admin, msg.queryId);
                return;
            }

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
                    metaCell,
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

            val grid = msg.meta.load().priceConfig.load();
            assert (grid.isValid()) throw ERROR_UNKNOWN_OP;
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
                recordCompletedDeployment(mutate st, key);
                refundRemainingMessageValue(pending.admin, pending.queryId);
                return;
            }

            // Readiness counts deployment but does not prove custody.
            if (!st.deployed.exists(key)) {
                st.deployed.set(key, ());
                st.deployedCount += 1;
            }

            if (msg.currentAdmin != pending.admin) {
                // After re-auction, return the parent without routing through the old registry.
                pending.phase = PHASE_RETURNING_PARENT;
                st.pending.set(key, pending.toCell());
                st.save();
                sendParentTransfer(
                    pending,
                    pending.admin,
                    0,
                    pending.handoffValue,
                    contract.getAddress(),
                );
                return;
            }

            pending.phase = PHASE_AWAITING_HANDOFF;
            st.pending.set(key, pending.toCell());
            st.save();
            sendParentTransfer(
                pending,
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
            recordCompletedDeployment(mutate st, key);
            refundRemainingMessageValue(pending.admin, pending.queryId);
        }

        RetryCollectionDeployment => {
            val st = lazy FactoryStorage.load();
            val key = collectionKey(msg.collectionAddress);
            assert (st.pending.exists(key)) throw ERROR_NOT_FROM_COLLECTION;
            val pending = st.pending.mustGet(key).load();
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
                // Probe a lost callback and retry the handoff in one funded operation.
                requestParentHandoffConfirmation(pending, expected);
                sendParentTransfer(
                    pending,
                    expected,
                    RESOLVER_PIN_FUND,
                    in.valueCoins - HANDOFF_CONFIRM_VALUE - FACTORY_GAS_MARGIN,
                    pending.admin,
                );
                return;
            }

            assert (pending.phase == PHASE_RETURNING_PARENT) throw ERROR_NOT_FROM_COLLECTION;
            sendParentTransfer(
                pending,
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

get fun get_deployed_count(): int {
    return FactoryStorage.load().deployedCount;
}
