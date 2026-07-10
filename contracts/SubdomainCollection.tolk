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
    version: "2.0.0"
    description: "Per-domain registry with Locked or Linked parent custody, minting, DNS and transferable admin."
    incomingMessages: AllowedCollectionMessage
    storage: CollectionStorage
    storageAtDeployment: CollectionSkeleton
}

type AllowedCollectionMessage =
    | RegisterSubdomain
    | SetContent
    | WithdrawFees
    | TransferAdmin
    | ProxyEditParentRecord
    | FillUpParent
    | EnforceResolver
    | SetLabelReserved
    | RescueNft
    | GetRoyaltyParams
    | ConfirmParentHandoff

fun emptyReserved(): map<uint256, ()> {
    val m: map<uint256, ()> = [];
    return m;
}

fun assertAdmin(senderAddress: address, admin: address) {
    assert (senderAddress == admin) throw ERROR_NOT_ADMIN;
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
        value: ton("0.05"),
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

// Rich bounce authenticates a failed item init and releases its label.
fun onBouncedMessage(in: InMessageBounced) {
    if (in.bouncedBody.remainingBitsCount() < 32 || in.bouncedBody.preloadUint(32) != 0xfffffffe) {
        return;
    }

    val rich = lazy RichBounceBody.fromSlice(in.bouncedBody);
    val originalBody = rich.originalBody.beginParse();
    if (originalBody.remainingBitsCount() < 32 || originalBody.preloadUint(32) != 0x2428aaa6) {
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

    if (!storage.minted.exists(init.index)) {
        return;
    }
    storage.minted.delete(init.index);
    // The set is authoritative; saturate its auxiliary count.
    if (storage.mintedCount > 0) {
        storage.mintedCount -= 1;
    }
    storage.save();

    val labelBits = init.label.load().remainingBitsCount();
    val price = storage.meta.load().priceConfig.load().priceForCharCount(labelBits / BYTE_SIZE);
    val refund = createMessage({
        bounce: BounceMode.NoBounce,
        dest: init.minter,
        value: price + in.valueCoins,
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
            reserved: emptyReserved(),
            minted: emptyReserved(),
            mintedCount: 0,
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
        // Parent landing either completes Locked creation or terminally upgrades Linked.
        if (in.senderAddress == storage.parentDomain) {
            val assigned = lazy OwnershipAssigned.fromSlice(in.body);
            var factoryReceipt: FactoryHandoffReceipt? = null;
            var handoffPayload = assigned.payload;
            if (handoffPayload.remainingBitsCount() > 0) {
                val payloadInRef = handoffPayload.loadBool();
                if (payloadInRef && handoffPayload.remainingRefsCount() > 0) {
                    handoffPayload = handoffPayload.loadRef().beginParse();
                }
            }
            if (
                assigned.oldOwnerAddress != null && assigned.oldOwnerAddress! == storage.master &&
                handoffPayload.remainingBitsCount() >= 32 &&
                handoffPayload.preloadUint(32) == 0x48414e44
            ) {
                val handoff = FactoryHandoff.fromSlice(handoffPayload);
                assert (handoff.deploymentId == assigned.queryId) throw ERROR_NOT_FROM_MASTER;
                factoryReceipt = FactoryHandoffReceipt {
                    deploymentId: handoff.deploymentId,
                    requestQueryId: handoff.requestQueryId,
                    intendedAdmin: handoff.intendedAdmin,
                    returnRequired: handoff.intendedAdmin != storage.admin,
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
            if (storage.isLinked) {
                storage.isLinked = false;
                storage.save();
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
            // Reject before reserving a label the basechain item cannot use.
            in.senderAddress.forceBasechain();

            val label = msg.label.load();
            val len = label.remainingBitsCount();
            val cfg = storage.meta.load().priceConfig.load();
            assert (
                len >= cfg.minChars * BYTE_SIZE
            ) throw ERROR_LABEL_TOO_SHORT;                                        // per-registry minimum
            assert (len <= MAX_DOMAIN_SIZE * BYTE_SIZE) throw ERROR_LABEL_TOO_LONG;
            assert (len % BYTE_SIZE == 0) throw ERROR_LABEL_INVALID_CHARS;
            assert (checkDomainString(label, len)) throw ERROR_LABEL_INVALID_CHARS;
            assert (label.remainingRefsCount() == 0) throw ERROR_LABEL_INVALID_CHARS;

            // Validate records before reserving the label.
            if (msg.initialRecords != null) {
                val _validatedRecords = msg.initialRecords.load();
            }

            val index = label.hash();
            assert (!storage.minted.exists(index)) throw ERROR_LABEL_TAKEN;

            if (storage.reserved.exists(index) && in.senderAddress != storage.admin) {
                throw ERROR_LABEL_RESERVED;
            }

            val price = cfg.priceForCharCount(len / BYTE_SIZE);
            assert (
                in.valueCoins >= price + ITEM_DEPLOY_COST + MINT_FEE_BUFFER
            ) throw ERROR_INSUFFICIENT_MINT_VALUE;

            val itemCode = subdomainItemCompiledCode();
            val deployMsg = createMessage({
                bounce: BounceMode.RichBounce,
                dest: calcDeployedItem(index, itemCode),
                value: ITEM_DEPLOY_COST,
                body: SubdomainInit {
                    queryId: msg.queryId,
                    index,
                    minter: in.senderAddress,
                    label: msg.label,
                    setWalletToMinter: msg.setWalletToMinter,
                    initialRecords: msg.initialRecords,
                },
            });
            deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);

            storage.minted.set(index, ());
            storage.mintedCount += 1;

            // Only a Locked collection owns the parent and can renew it.
            val nowTime = blockchain.now();
            if (
                !storage.isLinked && nowTime - storage.lastParentFillUp > PARENT_HEARTBEAT_INTERVAL
            ) {
                sendParentHeartbeat(storage.parentDomain, PARENT_HEARTBEAT_AMOUNT);
                storage.lastParentFillUp = nowTime;
            }
            storage.save();

            val refund = in.valueCoins - price - ITEM_DEPLOY_COST - MINT_FEE_BUFFER;
            if (refund > 0) {
                val refundMsg = createMessage({
                    body: Excesses { queryId: msg.queryId },
                    bounce: false,
                    dest: in.senderAddress,
                    value: refund,
                });
                refundMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
        }

        // ---------------- admin: set content ----------------
        SetContent => {
            assertAdmin(in.senderAddress, storage.admin);
            var newMeta = msg.meta.load();
            newMeta.priceConfig = storage.meta.load().priceConfig;
            storage.meta = newMeta.toCell();
            storage.save();
        }

        WithdrawFees => {
            assertAdmin(in.senderAddress, storage.admin);
            val balance = contract.getOriginalBalance();
            val keep = COLLECTION_MIN_BALANCE + FWD_FEE_RESERVE;
            var maxWithdraw = balance - in.valueCoins - keep;
            if (maxWithdraw < 0) {
                maxWithdraw = 0;
            }
            var amount = msg.amount;
            if (amount == 0 || amount > maxWithdraw) {
                amount = maxWithdraw;
            }
            if (amount > 0) {
                val payout = createMessage({
                    bounce: false,
                    dest: storage.admin,
                    value: amount,
                    body: beginCell().endCell(),
                });
                payout.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
        }

        // ---------------- admin: transfer role ----------------
        TransferAdmin => {
            assertAdmin(in.senderAddress, storage.admin);
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
            if (msg.reserved) {
                storage.reserved.set(msg.labelHash, ());
            } else {
                storage.reserved.delete(msg.labelHash);
            }
            storage.save();
        }

        // ---------------- admin: rescue NFT ----------------
        RescueNft => {
            assertAdmin(in.senderAddress, storage.admin);
            // Locked protects parent custody; Linked allows rescue of a mis-routed parent.
            assert (
                storage.isLinked || msg.nftAddress != storage.parentDomain
            ) throw ERROR_RESCUE_PARENT_FORBIDDEN;
            val emptyPayload = beginCell().endCell().beginParse();
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
                        forwardPayload: emptyPayload,
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
            val origin = storage.origin.load();
            if (origin.lastFactoryHandoff == null) {
                return;
            }
            val receipt = origin.lastFactoryHandoff!.load();
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
    return loader.parseLocked().mintedCount;
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
