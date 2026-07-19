import "dns-utils"
import "errors"
import "messages"
import "prices"
import "storage"
// Tier 1: one registry per parent domain. Custody/lock + mint + resolver + admin.
// check-disable-next-line import-path-can-use-mappings
import "../gen/SubdomainItem.code"

contract SubdomainCollection {
    author: "tolk-subdomains"
    version: "4.0.0"
    description: "Per-domain DNS registry with claimable Linked ownership, access policy and immutable pricing."
    incomingMessages: AllowedCollectionMessage
    storage: CollectionStorage
    storageAtDeployment: CollectionSkeleton
}

type AllowedCollectionMessage =
    | RegisterSubdomain
    | ItemReady
    | ReportStaticData
    | SetContent
    | SetAccessMode
    | SetAllowlistEntry
    | WithdrawFees
    | TransferAdmin
    | ProxyEditParentRecord
    | FillUpParent
    | EnforceResolver
    | SetLabelReserved
    | RescueNft
    | GetRoyaltyParams
    | ConfirmParentHandoff
    | RetryParentReturn
    | ConfirmMint

fun defaultPolicyState(): CollectionPolicyState {
    return {
        accessMode: ACCESS_PUBLIC,
        withdrawableRevenue: 0,
        allowlist: [],
        pendingMints: [],
        parentGeneration: 0,
        pendingParentReturn: null,
    };
}

fun assertAdmin(senderAddress: address, admin: address) {
    assert (senderAddress == admin) throw ERROR_NOT_ADMIN;
}

fun isValidAccessMode(accessMode: uint8): bool {
    return accessMode == ACCESS_PUBLIC || accessMode == ACCESS_ALLOWLIST ||
    accessMode == ACCESS_ADMIN_ONLY;
}

fun resolveMintAccess(
    policy: CollectionPolicyState,
    admin: address,
    minter: address,
): bool {
    if (minter == admin) {
        return true;
    }
    return policy.accessMode == ACCESS_PUBLIC ||
    (policy.accessMode == ACCESS_ALLOWLIST && policy.allowlist.exists(minter));
}

fun isParentHeartbeatDue(storage: CollectionStorage, nowTime: uint32): bool {
    return !storage.isLinked && nowTime - storage.lastParentFillUp > PARENT_HEARTBEAT_INTERVAL;
}

fun calculateMintFunding(
    storage: CollectionStorage,
    nowTime: uint32,
): coins {
    var funding = ITEM_DEPLOY_COST + MINT_FEE_BUFFER;
    if (isParentHeartbeatDue(storage, nowTime)) {
        funding += PARENT_HEARTBEAT_AMOUNT;
    }
    return funding;
}

fun calculateWithdrawAmount(
    requested: coins,
    withdrawableRevenue: coins,
    inboundValue: coins,
): coins {
    var physical = contract.getOriginalBalance() - inboundValue - COLLECTION_MIN_BALANCE -
    FWD_FEE_RESERVE;
    if (physical < 0) {
        physical = 0;
    }
    var available = withdrawableRevenue;
    if (available > physical) {
        available = physical;
    }
    if (requested == 0 || requested > available) {
        return available;
    }
    return requested;
}

fun sendRevenuePayout(recipient: address, amount: coins) {
    if (amount == 0) {
        return;
    }
    val payout = createMessage({
        bounce: BounceMode.NoBounce,
        dest: recipient,
        value: amount,
        body: beginCell().endCell(),
    });
    payout.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun parseLinkedParentAction(payload: TransferForwardPayload): LinkedParentAction? {
    var p = payload;
    try {
        val payloadInRef = p.loadBool();
        if (!payloadInRef) {
            return LinkedParentAction.fromSlice(p);
        }
        if (p.remainingBitsCount() != 0 || p.remainingRefsCount() != 1) {
            return null;
        }
        return LinkedParentAction.fromCell(p.loadRef());
    } catch {
        return null;
    }
}

fun isEmptyTep62ForwardPayload(payload: TransferForwardPayload): bool {
    val (bits, refs) = payload.remainingBitsAndRefsCount();
    if (bits != 1 || refs != 0) {
        return false;
    }
    return payload.preloadUint(1) == 0;
}

fun emptyTep62ForwardPayload(): TransferForwardPayload {
    return beginCell().storeBool(false).endCell().beginParse();
}

fun sendPendingParentReturn(parent: address, pending: PendingParentReturn) {
    val returnParent = createMessage({
        bounce: BounceMode.RichBounce,
        dest: parent,
        value: 0,
        body: TransferOwnership {
            queryId: pending.returnQueryId,
            transferData: {
                newOwnerAddress: pending.recipient,
                responseDestination: contract.getAddress(),
                customPayload: null,
                forwardAmount: 0,
                forwardPayload: emptyTep62ForwardPayload(),
            },
        },
    });
    returnParent.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

fun beginParentReturn(
    mutate storage: CollectionStorage,
    requestQueryId: uint64,
    recipient: address,
    inValue: coins,
) {
    var policy = storage.policy.load();
    policy.parentGeneration += 1;
    val canReturn = inValue >= MIN_PARENT_RETURN_VALUE;
    val pending: PendingParentReturn = {
        returnQueryId: policy.parentGeneration,
        requestQueryId,
        recipient,
        inFlight: canReturn,
    };
    policy.pendingParentReturn = pending.toCell();
    storage.policy = policy.toCell();
    storage.save();
    if (canReturn) {
        sendPendingParentReturn(storage.parentDomain, pending);
    }
}

fun sendParentHeartbeat(parent: address, amount: coins) {
    val heartbeatMessage = createMessage({
        bounce: true,
        dest: parent,
        value: amount,
        body: beginCell().endCell(),
    });
    heartbeatMessage.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun pinNextResolver(parent: address, queryId: uint64, mode: int) {
    val recordValue = beginCell()
        .storeRef(contract.getAddress().toNextResolver())
        .endCell()
        .beginParse();
    val resolverPinMessage = createMessage({
        bounce: true,
        dest: parent,
        value: RESOLVER_PIN_VALUE,
        body: ChangeDnsRecord {
            queryId,
            key: CAT_DNS_NEXT_RESOLVER,
            value: recordValue,
        },
    });
    resolverPinMessage.send(mode);
}

fun notifyFactory(
    master: address,
    deploymentId: uint64,
    queryId: uint64,
    parentDomain: address,
    creatorAdmin: address,
    currentAdmin: address,
    isLinked: bool,
    isNew: bool,
) {
    val ready = createMessage({
        bounce: BounceMode.NoBounce,
        dest: master,
        value: FACTORY_READY_VALUE,
        body: CollectionReady {
            deploymentId,
            queryId,
            parentDomain,
            admin: creatorAdmin,
            currentAdmin,
            isLinked,
            isNew,
        },
    });
    ready.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun notifyParentHandoffComplete(
    master: address,
    parentDomain: address,
    receipt: FactoryHandoffReceipt,
) {
    val complete = createMessage({
        bounce: BounceMode.NoBounce,
        dest: master,
        value: FACTORY_READY_VALUE,
        body: ParentHandoffComplete {
            deploymentId: receipt.deploymentId,
            queryId: receipt.requestQueryId,
            parentDomain,
            intendedAdmin: receipt.intendedAdmin,
        },
    });
    complete.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun finalizePendingMint(
    mutate storage: CollectionStorage,
    index: uint256,
    queryId: uint64,
    minter: address,
): bool {
    var policy = storage.policy.load();
    if (!policy.pendingMints.exists(index)) {
        return false;
    }
    val pending = policy.pendingMints.mustGet(index).load();
    if (pending.queryId != queryId || pending.minter != minter) {
        return false;
    }
    policy.pendingMints.delete(index);
    policy.withdrawableRevenue += pending.price;
    var names = storage.names.load();
    names.minted.set(index, ());
    names.mintedCount += 1;
    storage.names = names.toCell();
    storage.policy = policy.toCell();
    storage.save();
    return true;
}

fun processRegistration(
    senderAddress: address,
    inValue: coins,
    mutate storage: CollectionStorage,
    queryId: uint64,
    labelCell: Cell<RemainingBitsAndRefs>,
    setWalletToMinter: bool,
) {
    senderAddress.forceBasechain();

    val label = labelCell.load();
    val len = label.remainingBitsCount();
    val cfg = storage.meta.load().priceConfig.load();
    assert (len >= cfg.minChars * BYTE_SIZE) throw ERROR_LABEL_TOO_SHORT;
    assert (len <= MAX_DOMAIN_SIZE * BYTE_SIZE) throw ERROR_LABEL_TOO_LONG;
    assert (len % BYTE_SIZE == 0) throw ERROR_LABEL_INVALID_CHARS;
    assert (checkDomainString(label, len)) throw ERROR_LABEL_INVALID_CHARS;
    assert (label.remainingRefsCount() == 0) throw ERROR_LABEL_INVALID_CHARS;

    val index = label.hash();
    var policy = storage.policy.load();
    val names = storage.names.load();
    assert (!names.minted.exists(index)) throw ERROR_LABEL_TAKEN;
    assert (!policy.pendingMints.exists(index)) throw ERROR_LABEL_TAKEN;

    if (names.reserved.exists(index) && senderAddress != storage.admin) {
        throw ERROR_LABEL_RESERVED;
    }

    val price = cfg.priceForCharCount(len / BYTE_SIZE);
    val allowed = resolveMintAccess(policy, storage.admin, senderAddress);
    assert (allowed) throw ERROR_MINT_NOT_ALLOWED;
    val nowTime = blockchain.now();
    val mintFunding = calculateMintFunding(storage, nowTime);
    assert (inValue >= price + mintFunding) throw ERROR_INSUFFICIENT_MINT_VALUE;

    policy
        .pendingMints
        .set(
            index,
            PendingMint {
                queryId,
                minter: senderAddress,
                price,
            }.toCell(),
        );
    storage.policy = policy.toCell();

    val itemCode = subdomainItemCompiledCode();
    val deployMsg = createMessage({
        bounce: BounceMode.RichBounce,
        dest: calcDeployedItem(index, itemCode),
        value: ITEM_DEPLOY_COST,
        body: SubdomainInit {
            queryId,
            index,
            minter: senderAddress,
            label: labelCell,
            setWalletToMinter,
        },
    });
    deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);

    if (isParentHeartbeatDue(storage, nowTime)) {
        sendParentHeartbeat(storage.parentDomain, PARENT_HEARTBEAT_AMOUNT);
        storage.lastParentFillUp = nowTime;
    }
    storage.save();

    val refund = inValue - price - mintFunding;
    if (refund > 0) {
        val refundMsg = createMessage({
            body: Excesses { queryId },
            bounce: BounceMode.NoBounce,
            dest: senderAddress,
            value: refund,
        });
        refundMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
    }
}

// Rich bounces authenticate failed item initialization.
fun onBouncedMessage(in: InMessageBounced) {
    if (in.bouncedBody.remainingBitsCount() < 32 || in.bouncedBody.preloadUint(32) != 0xfffffffe) {
        return;
    }

    val rich = lazy RichBounceBody.fromSlice(in.bouncedBody);
    val originalBody = rich.originalBody.beginParse();
    if (originalBody.remainingBitsCount() < 32) {
        return;
    }

    if (originalBody.preloadUint(32) == 0x5fcc3d14) {
        val loader = startLoadingCollection();
        if (!loader.isLocked()) {
            return;
        }
        var storage = loader.parseLocked();
        if (in.senderAddress != storage.parentDomain) {
            return;
        }

        var transfer: TransferOwnership? = null;
        try {
            transfer = TransferOwnership.fromSlice(originalBody);
        } catch {
            return;
        }
        val returned = transfer!;

        if (storage.isLinked) {
            var policy = storage.policy.load();
            if (policy.pendingParentReturn == null) {
                return;
            }
            var pending = policy.pendingParentReturn!.load();
            if (
                !pending.inFlight || returned.queryId != pending.returnQueryId ||
                returned.transferData.newOwnerAddress != pending.recipient ||
                returned.transferData.responseDestination == null ||
                returned.transferData.responseDestination! != contract.getAddress() ||
                returned.transferData.customPayload != null ||
                returned.transferData.forwardAmount != 0 ||
                !isEmptyTep62ForwardPayload(returned.transferData.forwardPayload)
            ) {
                return;
            }
            pending.inFlight = false;
            policy.pendingParentReturn = pending.toCell();
            storage.policy = policy.toCell();
            storage.save();
            return;
        }

        var origin = storage.origin.load();
        if (origin.lastFactoryHandoff == null) {
            return;
        }
        var receipt = origin.lastFactoryHandoff!.load();
        val handoff = parseFactoryHandoffPayload(returned.transferData.forwardPayload);
        if (
            !receipt.returnRequired || !receipt.returnInFlight || handoff == null ||
            returned.queryId != receipt.deploymentId ||
            returned.transferData.newOwnerAddress != receipt.intendedAdmin ||
            returned.transferData.responseDestination == null ||
            returned.transferData.responseDestination! != storage.master ||
            returned.transferData.customPayload != null ||
            returned.transferData.forwardAmount != 0 ||
            handoff!.deploymentId != receipt.deploymentId ||
            handoff!.requestQueryId != receipt.requestQueryId ||
            handoff!.intendedAdmin != receipt.intendedAdmin
        ) {
            return;
        }
        receipt.returnInFlight = false;
        origin.lastFactoryHandoff = receipt.toCell();
        storage.origin = origin.toCell();
        storage.save();
        return;
    }

    if (originalBody.preloadUint(32) != 0x2428aaa6) {
        return;
    }

    val init = lazy SubdomainInit.fromSlice(originalBody);
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return;
    }
    var storage = loader.parseLocked();
    val itemCode = subdomainItemCompiledCode();
    assert (
        in.senderAddress == calcDeployedItem(init.index, itemCode).calculateAddress()
    ) throw ERROR_NOT_FROM_COLLECTION;
    assert (init.label.load().hash() == init.index) throw ERROR_INDEX_MISMATCH;

    var policy = storage.policy.load();
    if (!policy.pendingMints.exists(init.index)) {
        return;
    }
    val pending = policy.pendingMints.mustGet(init.index).load();
    if (pending.queryId != init.queryId || pending.minter != init.minter) {
        return;
    }
    policy.pendingMints.delete(init.index);
    storage.policy = policy.toCell();
    storage.save();

    val refund = createMessage({
        bounce: BounceMode.NoBounce,
        dest: init.minter,
        value: pending.price + in.valueCoins,
        body: Excesses { queryId: init.queryId },
    });
    refund.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun onInternalMessage(in: InMessage) {
    val loader = startLoadingCollection();

    // ============================ SKELETON (not locked) ============================
    if (!loader.isLocked()) {
        // Ignore messages until the master initializes this skeleton.
        if (
            in.body.isEmpty() || in.body.remainingBitsCount() < 32 ||
            in.body.preloadUint(32) != 0x6c0c4b17
        ) {
            return;
        }

        val lock = lazy LockCollection.fromSlice(in.body);
        val sk = loader.parseSkeleton();
        assert (in.senderAddress == sk.master) throw ERROR_NOT_FROM_MASTER;
        assert (lock.parentDomain == sk.parentDomain) throw ERROR_NOT_FROM_MASTER;
        assert (lock.isLinked == sk.isLinked) throw ERROR_NOT_FROM_MASTER;
        if (sk.isLinked) {
            // Enforce the creator committed into Linked StateInit.
            assert (lock.admin == sk.linkedAdmin) throw ERROR_NOT_ADMIN;
        }
        // The factory validates workchains before transferring custody.

        val locked: CollectionStorage = {
            master: sk.master,
            parentDomain: sk.parentDomain,
            admin: lock.admin,
            origin: CollectionOrigin {
                linkedAdmin: sk.linkedAdmin,
                isLinkedAtDeployment: sk.isLinked,
                lastFactoryHandoff: null,
            }.toCell(),
            // Custody mode comes from StateInit, not the lock message.
            isLinked: sk.isLinked,
            lastParentFillUp: blockchain.now(),
            meta: lock.meta,
            names: CollectionNames {
                reserved: [],
                minted: [],
                mintedCount: 0,
            }.toCell(),
            policy: defaultPolicyState().toCell(),
        };
        locked.save();
        notifyFactory(
            sk.master,
            lock.deploymentId,
            lock.queryId,
            sk.parentDomain,
            lock.admin,
            lock.admin,
            sk.isLinked,
            true,
        );
        return;
    }

    // ============================ LOCKED ============================
    var storage = loader.parseLocked();

    if (in.body.isEmpty()) {
        return;
    }

    if (in.body.remainingBitsCount() >= 32 && in.body.preloadUint(32) == 0x05138d91) {
        // The canonical parent is the only trust anchor for both Locked handoff and Linked claims.
        if (in.senderAddress == storage.parentDomain) {
            val assigned = lazy OwnershipAssigned.fromSlice(in.body);

            if (storage.isLinked) {
                assert (assigned.oldOwnerAddress != null) throw ERROR_NULL_OLD_OWNER;
                val claimant = assigned.oldOwnerAddress!;
                val parsedAction = parseLinkedParentAction(assigned.payload);
                if (parsedAction == null) {
                    beginParentReturn(
                        mutate storage,
                        assigned.queryId,
                        claimant,
                        in.valueCoins,
                    );
                    return;
                }
                val action = parsedAction!;

                if (action.action == LINKED_ACTION_CONVERT_LOCKED) {
                    var policy = storage.policy.load();
                    policy.pendingParentReturn = null;
                    storage.admin = claimant;
                    storage.isLinked = false;
                    storage.policy = policy.toCell();
                    storage.save();
                    pinNextResolver(
                        storage.parentDomain,
                        assigned.queryId,
                        SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
                    );
                    return;
                }

                if (action.action != LINKED_ACTION_CLAIM) {
                    beginParentReturn(
                        mutate storage,
                        assigned.queryId,
                        claimant,
                        in.valueCoins,
                    );
                    return;
                }

                storage.admin = claimant;
                var policy = storage.policy.load();
                val amount = calculateWithdrawAmount(0, policy.withdrawableRevenue, in.valueCoins);
                policy.withdrawableRevenue -= amount;
                storage.policy = policy.toCell();
                sendRevenuePayout(claimant, amount);
                beginParentReturn(mutate storage, assigned.queryId, claimant, in.valueCoins);
                return;
            }

            var factoryReceipt: FactoryHandoffReceipt? = null;
            val handoff = parseFactoryHandoffPayload(assigned.payload);
            if (
                assigned.oldOwnerAddress != null && assigned.oldOwnerAddress! == storage.master &&
                handoff != null
            ) {
                assert (handoff!.deploymentId == assigned.queryId) throw ERROR_NOT_FROM_MASTER;
                factoryReceipt = FactoryHandoffReceipt {
                    deploymentId: handoff!.deploymentId,
                    requestQueryId: handoff!.requestQueryId,
                    intendedAdmin: handoff!.intendedAdmin,
                    returnRequired: handoff!.intendedAdmin != storage.admin,
                    returnInFlight: handoff!.intendedAdmin != storage.admin,
                };
                var updatedOrigin = storage.origin.load();
                updatedOrigin.lastFactoryHandoff = factoryReceipt!.toCell();
                storage.origin = updatedOrigin.toCell();
                storage.save();
            }

            // Return a re-auctioned parent when the active registry has a different admin.
            if (factoryReceipt != null && factoryReceipt!.returnRequired) {
                val returnParent = createMessage({
                    bounce: BounceMode.RichBounce,
                    dest: storage.parentDomain,
                    value: 0,
                    body: TransferOwnership {
                        queryId: factoryReceipt!.deploymentId,
                        transferData: {
                            newOwnerAddress: factoryReceipt!.intendedAdmin,
                            // The factory keeps pending until this canonical parent acknowledgement.
                            responseDestination: storage.master,
                            customPayload: null,
                            forwardAmount: 0,
                            forwardPayload: beginCell()
                                .storeBool(true)
                                .storeRef(
                                    FactoryHandoff {
                                        deploymentId: factoryReceipt!.deploymentId,
                                        requestQueryId: factoryReceipt!.requestQueryId,
                                        intendedAdmin: factoryReceipt!.intendedAdmin,
                                    }.toCell(),
                                )
                                .endCell()
                                .beginParse(),
                        },
                    },
                });
                returnParent.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
                return;
            }
            // Commit custody even if the resolver pin must be repaired later.
            pinNextResolver(
                storage.parentDomain,
                assigned.queryId,
                SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
            );
            if (factoryReceipt != null) {
                notifyParentHandoffComplete(storage.master, storage.parentDomain, factoryReceipt!);
            }
        }
        return;
    }

    if (in.body.remainingBitsCount() >= 32 && in.body.preloadUint(32) == 0xd53276db) {
        val acknowledgement = lazy Excesses.fromSlice(in.body);
        var policy = storage.policy.load();
        if (
            in.senderAddress == storage.parentDomain && policy.pendingParentReturn != null &&
            policy.pendingParentReturn!.load().returnQueryId == acknowledgement.queryId
        ) {
            val pending = policy.pendingParentReturn!.load();
            policy.pendingParentReturn = null;
            storage.policy = policy.toCell();
            storage.save();
            val refund = createMessage({
                bounce: BounceMode.NoBounce,
                dest: pending.recipient,
                value: 0,
                body: Excesses { queryId: pending.requestQueryId },
            });
            refund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        return;
    }

    // Active-address retries report current state and return their attached value.
    if (in.body.remainingBitsCount() >= 32 && in.body.preloadUint(32) == 0x6c0c4b17) {
        val duplicate = lazy LockCollection.fromSlice(in.body);
        assert (in.senderAddress == storage.master) throw ERROR_NOT_FROM_MASTER;
        val origin = storage.origin.load();
        assert (duplicate.parentDomain == storage.parentDomain) throw ERROR_NOT_FROM_MASTER;
        assert (duplicate.isLinked == origin.isLinkedAtDeployment) throw ERROR_NOT_FROM_MASTER;
        notifyFactory(
            storage.master,
            duplicate.deploymentId,
            duplicate.queryId,
            duplicate.parentDomain,
            duplicate.admin,
            storage.admin,
            duplicate.isLinked,
            false,
        );
        val duplicateRefund = createMessage({
            bounce: false,
            dest: duplicate.admin,
            value: 0,
            body: Excesses { queryId: duplicate.queryId },
        });
        duplicateRefund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        return;
    }

    val msg = lazy AllowedCollectionMessage.fromSlice(in.body);

    match (msg) {
        // ---------------- MINT ----------------
        RegisterSubdomain => {
            processRegistration(
                in.senderAddress,
                in.valueCoins,
                mutate storage,
                msg.queryId,
                msg.label,
                msg.setWalletToMinter,
            );
        }

        ItemReady => {
            val itemCode = subdomainItemCompiledCode();
            assert (
                in.senderAddress == calcDeployedItem(msg.index, itemCode).calculateAddress()
            ) throw ERROR_NOT_FROM_COLLECTION;
            finalizePendingMint(mutate storage, msg.index, msg.queryId, msg.minter);
        }

        ReportStaticData => {
            val itemCode = subdomainItemCompiledCode();
            assert (
                in.senderAddress == calcDeployedItem(msg.itemIndex, itemCode).calculateAddress()
            ) throw ERROR_NOT_FROM_COLLECTION;
            assert (msg.collectionAddress == contract.getAddress()) throw ERROR_NOT_FROM_COLLECTION;
            val policy = storage.policy.load();
            if (!policy.pendingMints.exists(msg.itemIndex)) {
                return;
            }
            val pending = policy.pendingMints.mustGet(msg.itemIndex).load();
            finalizePendingMint(
                mutate storage,
                msg.itemIndex,
                pending.queryId,
                pending.minter,
            );
        }

        // ---------------- admin: set content ----------------
        SetContent => {
            assertAdmin(in.senderAddress, storage.admin);
            var newMeta = msg.meta.load();
            newMeta.priceConfig = storage.meta.load().priceConfig;
            storage.meta = newMeta.toCell();
            storage.save();
        }

        SetAccessMode => {
            assertAdmin(in.senderAddress, storage.admin);
            assert (isValidAccessMode(msg.accessMode)) throw ERROR_INVALID_ACCESS_MODE;
            var policy = storage.policy.load();
            policy.accessMode = msg.accessMode;
            storage.policy = policy.toCell();
            storage.save();
        }

        SetAllowlistEntry => {
            assertAdmin(in.senderAddress, storage.admin);
            msg.wallet.forceBasechain();
            var policy = storage.policy.load();
            if (msg.allowed) {
                policy.allowlist.set(msg.wallet, ());
            } else {
                policy.allowlist.delete(msg.wallet);
            }
            storage.policy = policy.toCell();
            storage.save();
        }

        WithdrawFees => {
            assertAdmin(in.senderAddress, storage.admin);
            assert (!storage.isLinked) throw ERROR_LINKED_OWNER_PROOF_REQUIRED;
            var policy = storage.policy.load();
            val amount = calculateWithdrawAmount(
                msg.amount,
                policy.withdrawableRevenue,
                in.valueCoins,
            );
            policy.withdrawableRevenue -= amount;
            storage.policy = policy.toCell();
            storage.save();
            sendRevenuePayout(storage.admin, amount);
        }

        // ---------------- admin: transfer role ----------------
        TransferAdmin => {
            assertAdmin(in.senderAddress, storage.admin);
            assert (!storage.isLinked) throw ERROR_LINKED_OWNER_PROOF_REQUIRED;
            // An unusable admin would permanently lock privileged operations.
            msg.newAdmin.forceBasechain();
            val prev = storage.admin;
            storage.admin = msg.newAdmin;
            storage.save();
            val notify = createMessage({
                bounce: false,
                dest: msg.newAdmin,
                value: 0,
                body: AdminAssigned {
                    queryId: msg.queryId,
                    prevAdmin: prev,
                },
            });
            notify.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        // ---------------- admin: proxy-edit parent record ----------------
        ProxyEditParentRecord => {
            assertAdmin(in.senderAddress, storage.admin);
            assert (!storage.isLinked) throw ERROR_LINKED_NO_CUSTODY; // we don't own the parent
            assert (msg.key != CAT_DNS_NEXT_RESOLVER) throw ERROR_CANNOT_EDIT_RESOLVER;
            val relay = createMessage({
                bounce: true,
                dest: storage.parentDomain,
                value: 0,
                body: ChangeDnsRecord {
                    queryId: msg.queryId,
                    key: msg.key,
                    value: msg.value,
                },
            });
            relay.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        // ---------------- public: fill up parent (caller-funded) ----------------
        FillUpParent => {
            // Caller-funded renewal forwards only the incoming remainder.
            assert (
                !storage.isLinked
            ) throw ERROR_LINKED_NO_CUSTODY;                          // the owner renews their own .ton
            assert (in.valueCoins >= MIN_PARENT_FILL) throw ERROR_INSUFFICIENT_BALANCE;
            val heartbeat = createMessage({
                bounce: true,
                dest: storage.parentDomain,
                value: 0,
                body: beginCell().endCell(),
            });
            heartbeat.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
            storage.lastParentFillUp = blockchain.now();
            storage.save();
        }

        // ---------------- public: enforce resolver ----------------
        EnforceResolver => {
            // Caller must fund the pin so spamming this drains the caller, not the collection.
            assert (
                !storage.isLinked
            ) throw ERROR_LINKED_NO_CUSTODY;                          // we can't write the parent's records
            assert (in.valueCoins >= RESOLVER_PIN_FUND) throw ERROR_INSUFFICIENT_BALANCE;
            pinNextResolver(storage.parentDomain, msg.queryId, SEND_MODE_PAY_FEES_SEPARATELY);
        }

        SetLabelReserved => {
            assertAdmin(in.senderAddress, storage.admin);
            var names = storage.names.load();
            if (msg.reserved) {
                names.reserved.set(msg.labelHash, ());
            } else {
                names.reserved.delete(msg.labelHash);
            }
            storage.names = names.toCell();
            storage.save();
        }

        // ---------------- admin: rescue NFT ----------------
        RescueNft => {
            assertAdmin(in.senderAddress, storage.admin);
            // The cached Linked admin is not proof of current parent ownership.
            assert (msg.nftAddress != storage.parentDomain) throw ERROR_RESCUE_PARENT_FORBIDDEN;
            val rescueMsg = createMessage({
                bounce: true,
                dest: msg.nftAddress,
                value: 0,
                body: TransferOwnership {
                    queryId: msg.queryId,
                    transferData: {
                        newOwnerAddress: msg.toAddress,
                        responseDestination: storage.admin,
                        customPayload: null,
                        forwardAmount: 0,
                        forwardPayload: emptyTep62ForwardPayload(),
                    },
                },
            });
            rescueMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        // ---------------- TEP-66: royalty params query ----------------
        GetRoyaltyParams => {
            val reply = createMessage({
                bounce: false,
                dest: in.senderAddress,
                value: 0,
                body: ReportRoyaltyParams {
                    queryId: msg.queryId,
                    numerator: 0,
                    denominator: 1000,
                    destination: storage.admin,
                },
            });
            reply.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        ConfirmParentHandoff => {
            assert (in.senderAddress == storage.master) throw ERROR_NOT_FROM_MASTER;
            assert (msg.parentDomain == storage.parentDomain) throw ERROR_NOT_FROM_MASTER;
            var origin = storage.origin.load();
            if (origin.lastFactoryHandoff == null) {
                return;
            }
            var receipt = origin.lastFactoryHandoff!.load();
            if (
                receipt.deploymentId != msg.deploymentId || receipt.requestQueryId != msg.queryId ||
                receipt.intendedAdmin != msg.intendedAdmin
            ) {
                return;
            }

            if (!receipt.returnRequired) {
                notifyParentHandoffComplete(storage.master, storage.parentDomain, receipt);
                return;
            }

            if (receipt.returnInFlight) {
                return;
            }

            receipt.returnInFlight = true;
            origin.lastFactoryHandoff = receipt.toCell();
            storage.origin = origin.toCell();
            storage.save();

            // Recover an interrupted return after TransferAdmin raced the handoff.
            val returnParent = createMessage({
                bounce: BounceMode.RichBounce,
                dest: storage.parentDomain,
                value: 0,
                body: TransferOwnership {
                    queryId: receipt.deploymentId,
                    transferData: {
                        newOwnerAddress: receipt.intendedAdmin,
                        responseDestination: storage.master,
                        customPayload: null,
                        forwardAmount: 0,
                        forwardPayload: beginCell()
                            .storeBool(true)
                            .storeRef(
                                FactoryHandoff {
                                    deploymentId: receipt.deploymentId,
                                    requestQueryId: receipt.requestQueryId,
                                    intendedAdmin: receipt.intendedAdmin,
                                }.toCell(),
                            )
                            .endCell()
                            .beginParse(),
                    },
                },
            });
            returnParent.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        RetryParentReturn => {
            var policy = storage.policy.load();
            assert (storage.isLinked) throw ERROR_LINKED_NO_CUSTODY;
            assert (policy.pendingParentReturn != null) throw ERROR_NO_PARENT_RETURN;
            var pending = policy.pendingParentReturn!.load();
            assert (!pending.inFlight) throw ERROR_PARENT_TRANSFER_IN_FLIGHT;
            assert (in.valueCoins >= MIN_PARENT_RETURN_VALUE) throw ERROR_INSUFFICIENT_BALANCE;
            pending.inFlight = true;
            policy.pendingParentReturn = pending.toCell();
            storage.policy = policy.toCell();
            storage.save();
            sendPendingParentReturn(storage.parentDomain, pending);
        }

        ConfirmMint => {
            val policy = storage.policy.load();
            assert (policy.pendingMints.exists(msg.index)) throw ERROR_MINT_NOT_PENDING;
            assert (in.valueCoins >= MIN_CONFIRM_MINT_VALUE) throw ERROR_INSUFFICIENT_BALANCE;
            val item = calcDeployedItem(msg.index, subdomainItemCompiledCode()).calculateAddress();
            val probe = createMessage({
                bounce: BounceMode.NoBounce,
                dest: item,
                value: 0,
                body: GetStaticData { queryId: msg.queryId },
            });
            probe.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        else => throw ERROR_UNKNOWN_OP,
    }
}

get fun get_collection_data(): CollectionDataReply {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return {
            nextItemIndex: -1,
            content: beginCell().endCell(),
            ownerAddress: null,
        };
    }
    val st = loader.parseLocked();
    return {
        // TEP-62 reserves -1 for non-sequential collections.
        nextItemIndex: -1,
        content: st.meta.load().collectionContent,
        ownerAddress: st.admin,
    };
}

// TEP-66, with zero royalty.
get fun royalty_params(): (int, int, address) {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return (0, 1000, contract.getAddress());
    }
    return (0, 1000, loader.parseLocked().admin);
}

get fun get_nft_address_by_index(index: int): address {
    return calcDeployedItem(index, subdomainItemCompiledCode()).calculateAddress();
}

get fun get_last_parent_fill_up(): int {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return 0;
    }
    return loader.parseLocked().lastParentFillUp;
}

get fun get_minted_count(): int {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return 0;
    }
    return loader.parseLocked().names.load().mintedCount;
}

get fun get_is_mint_pending(index: uint256): bool {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return false;
    }
    return loader.parseLocked().policy.load().pendingMints.exists(index);
}

get fun get_nft_content(_index: int, individualContent: cell): cell {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return beginCell().endCell();
    }
    val base = loader.parseLocked().meta.load().itemContentBaseUri;
    return beginCell().storeSlice(base.beginParse()).storeRef(individualContent).endCell();
}

get fun get_price(charCount: int): coins {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return 0;
    }
    return loader.parseLocked().meta.load().priceConfig.load().priceForCharCount(charCount);
}

get fun get_access_mode(): int {
    val loader = startLoadingCollection();
    return loader.isLocked() ? loader.parseLocked().policy.load().accessMode : ACCESS_PUBLIC;
}

get fun get_withdrawable_revenue(): coins {
    val loader = startLoadingCollection();
    return loader.isLocked() ? loader.parseLocked().policy.load().withdrawableRevenue : 0;
}

get fun get_is_allowlisted(wallet: address): bool {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return false;
    }
    return loader.parseLocked().policy.load().allowlist.exists(wallet);
}

get fun get_mint_quote(wallet: address, charCount: int): MintQuoteReply {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return {
            allowed: false,
            effectivePrice: 0,
            requiredValue: 0,
        };
    }
    val storage = loader.parseLocked();
    val policy = storage.policy.load();
    val config = storage.meta.load().priceConfig.load();
    if (charCount < config.minChars || charCount > MAX_DOMAIN_SIZE) {
        return {
            allowed: false,
            effectivePrice: 0,
            requiredValue: 0,
        };
    }
    val effectivePrice = config.priceForCharCount(charCount);
    val allowed = wallet.getWorkchain() == BASECHAIN &&
    resolveMintAccess(policy, storage.admin, wallet);
    return {
        allowed,
        effectivePrice,
        requiredValue: effectivePrice +
        calculateMintFunding(
            storage,
            blockchain.now(),
        ),
    };
}

get fun get_parent_return(): ParentReturnReply {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return {
            pending: false,
            returnQueryId: 0,
            requestQueryId: 0,
            recipient: null,
            inFlight: false,
        };
    }
    val pendingCell = loader.parseLocked().policy.load().pendingParentReturn;
    if (pendingCell == null) {
        return {
            pending: false,
            returnQueryId: 0,
            requestQueryId: 0,
            recipient: null,
            inFlight: false,
        };
    }
    val pending = pendingCell!.load();
    return {
        pending: true,
        returnQueryId: pending.returnQueryId,
        requestQueryId: pending.requestQueryId,
        recipient: pending.recipient,
        inFlight: pending.inFlight,
    };
}

// the registry's chosen minimum subdomain length (1..4); 0 if not locked
get fun get_min_chars(): int {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return 0;
    }
    return loader.parseLocked().meta.load().priceConfig.load().minChars;
}

get fun get_admin(): address? {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return null;
    }
    return loader.parseLocked().admin;
}

get fun get_parent_domain(): address {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return loader.parseSkeleton().parentDomain;
    }
    return loader.parseLocked().parentDomain;
}

// Immutable creator witness; Locked collections return the master sentinel.
get fun get_linked_admin(): address {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return loader.parseSkeleton().linkedAdmin;
    }
    return loader.parseLocked().origin.load().linkedAdmin;
}

get fun is_locked(): bool {
    return startLoadingCollection().isLocked();
}

// Current custody mode; is_locked() only reports initialization.
get fun get_is_linked(): bool {
    val loader = startLoadingCollection();
    if (!loader.isLocked()) {
        return false;
    }
    return loader.parseLocked().isLinked;
}

get fun dnsresolve(subdomain: slice, _category: int): DnsResolveResponse {
    val startsWithZeroByte = dnsQueryStartsWithZero(subdomain);

    if (startsWithZeroByte && subdomain.remainingBitsCount() == BYTE_SIZE) {
        return { resolvedPrefixLengthBits: BYTE_SIZE, resolvedRecord: null };
    }

    if (startsWithZeroByte) {
        subdomain.skipBits(BYTE_SIZE);
    }

    val topBits = getTopDomainBits(subdomain);
    val topLabel = subdomain.loadBits(topBits);
    val index = topLabel.hash();

    val itemAddr = calcDeployedItem(index, subdomainItemCompiledCode()).calculateAddress();

    return {
        resolvedPrefixLengthBits: topBits + (startsWithZeroByte ? BYTE_SIZE : 0),
        resolvedRecord: itemAddr.toNextResolver(),
    };
}
