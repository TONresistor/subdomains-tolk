// Tier 1: one registry per parent domain. Custody/lock + mint + resolver + admin.
import "@gen/SubdomainItem.code"
import "dns-utils"
import "errors"
import "messages"
import "prices"
import "storage"

contract SubdomainCollection {
    author: "tolk-subdomains"
    version: "1.0.0"
    description: "Per-domain subdomain registry: custody+lock of the parent, mint, resolver, transferable admin."
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

fun emptyReserved(): map<uint256, ()> {
    var m: map<uint256, ()> = [];
    return m;
}

fun assertAdmin(senderAddress: address, admin: address) {
    assert (senderAddress == admin) throw ERROR_NOT_ADMIN;
}

fun sendParentHeartbeat(parent: address, amount: coins) {
    createMessage({
        bounce: true,
        dest: parent,
        value: amount,
        body: beginCell().endCell(),
    }).send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun pinNextResolver(parent: address, queryId: uint64, mode: int) {
    val recordValue = beginCell()
        .storeRef(contract.getAddress().toNextResolver())
        .endCell()
        .beginParse();
    createMessage({
        bounce: true,
        dest: parent,
        value: ton("0.05"),
        body: ChangeDnsRecord {
            queryId,
            key: CAT_DNS_NEXT_RESOLVER,
            value: recordValue,
        },
    }).send(mode);
}

fun onBouncedMessage(in: InMessageBounced) {}

fun onInternalMessage(in: InMessage) {
    val loader = startLoadingCollection();

    // ============================ SKELETON (not locked) ============================
    if (!loader.isLocked()) {
        // Only a LockCollection from the master locks us. Absorb anything else without throwing:
        // a parent OwnershipAssigned that wins the cross-sender race against LockCollection would
        // otherwise abort here (the pin then relies on EnforceResolver post-create).
        if (
            in.body.isEmpty() || in.body.remainingBitsCount() < 32 ||
            in.body.preloadUint(32) != 0x6c0c4b17
        ) {
            return;
        }

        val lock = lazy LockCollection.fromSlice(in.body);
        val sk = loader.parseSkeleton();
        assert (in.senderAddress == sk.master) throw ERROR_NOT_FROM_MASTER;
        // No admin-workchain throw here: the factory (master) already validated it before dispatching
        // the .ton. Throwing post-handoff would strand the .ton (the v2 incident class).

        val locked: CollectionStorage = {
            master: sk.master,
            parentDomain: sk.parentDomain,
            admin: lock.admin,
            lastParentFillUp: blockchain.now(),
            meta: lock.meta,
            reserved: emptyReserved(),
            minted: emptyReserved(),
            mintedCount: 0,
        };
        locked.save();
        return;
    }

    // ============================ LOCKED ============================
    var storage = loader.parseLocked();

    if (in.body.isEmpty()) {
        return;
    }

    if (in.body.remainingBitsCount() >= 32 && in.body.preloadUint(32) == 0x05138d91) {
        if (in.senderAddress == storage.parentDomain) {
            val assigned = lazy OwnershipAssigned.fromSlice(in.body);
            pinNextResolver(storage.parentDomain, assigned.queryId, SEND_MODE_PAY_FEES_SEPARATELY);
        }
        return;
    }

    if (in.body.remainingBitsCount() >= 32 && in.body.preloadUint(32) == 0xd53276db) {
        return;
    }

    val msg = lazy AllowedCollectionMessage.fromSlice(in.body);

    match (msg) {
        // ---------------- MINT ----------------
        RegisterSubdomain => {
            // Reject masterchain minters up-front: the item init also forces basechain, so without
            // this guard a masterchain mint would bounce the deploy AFTER the label is marked minted,
            // bricking the slot permanently and keeping the price. Fail here so it refunds instead.
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

            // Validate the records the item would load, so a malformed cell fails here (refund)
            // rather than bouncing the item deploy after the slot is marked minted.
            if (msg.initialRecords != null) {
                msg.initialRecords.load();
            }

            val index = label.hash();
            assert (!storage.minted.exists(index)) throw ERROR_LABEL_TAKEN;

            if (storage.reserved.exists(index) && in.senderAddress != storage.admin) {
                throw ERROR_LABEL_RESERVED;
            }

            val price = cfg.priceForCharCount(len / BYTE_SIZE);
            assert (
                in.valueCoins >= price + ITEM_DEPLOY_COST + MINT_FEE_BUFFER + PER_NAME_RENT_RESERVE
            ) throw ERROR_INSUFFICIENT_MINT_VALUE;

            val itemCode = subdomainItemCompiledCode();
            val deployMsg = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: calcDeployedItem(index, itemCode),
                value: ITEM_DEPLOY_COST,
                body: SubdomainInit {
                    queryId: msg.queryId,
                    minter: in.senderAddress,
                    label: msg.label,
                    setWalletToMinter: msg.setWalletToMinter,
                    initialRecords: msg.initialRecords,
                },
            });
            deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);

            storage.minted.set(index, ());
            storage.mintedCount += 1;

            val nowTime = blockchain.now();
            if (nowTime - storage.lastParentFillUp > PARENT_HEARTBEAT_INTERVAL) {
                sendParentHeartbeat(storage.parentDomain, PARENT_HEARTBEAT_AMOUNT);
                storage.lastParentFillUp = nowTime;
            }
            storage.save();

            val refund = in.valueCoins - price - ITEM_DEPLOY_COST - MINT_FEE_BUFFER -
            PER_NAME_RENT_RESERVE;
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
            val keep = COLLECTION_MIN_BALANCE + LEASE_RESERVE + FWD_FEE_RESERVE +
            storage.mintedCount * PER_NAME_RENT_RESERVE;
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
            // Reject a masterchain/garbage new admin: an unusable admin would brick every admin op
            // (withdraw included) and strand revenue with no recovery on a non-upgradeable contract.
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

        // ---------------- public: fill up parent ----------------
        FillUpParent => {
            // Throttle the public renew (same window as the mint auto-heartbeat) so a stranger
            // cannot spam it to shovel collection revenue into the unrecoverable parent every block.
            val nowTime = blockchain.now();
            if (nowTime - storage.lastParentFillUp <= PARENT_HEARTBEAT_INTERVAL) {
                return;
            }
            val balance = contract.getOriginalBalance();
            val available = balance - COLLECTION_MIN_BALANCE - FWD_FEE_RESERVE -
            storage.mintedCount * PER_NAME_RENT_RESERVE;
            var amount = PARENT_FILL_AMOUNT;
            if (amount > available) {
                amount = available;
            }
            assert (amount > 0) throw ERROR_INSUFFICIENT_BALANCE;
            sendParentHeartbeat(storage.parentDomain, amount);
            storage.lastParentFillUp = nowTime;
            storage.save();
        }

        // ---------------- public: enforce resolver ----------------
        EnforceResolver => {
            // Caller must fund the pin so spamming this drains the caller, not the collection.
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
            assert (msg.nftAddress != storage.parentDomain) throw ERROR_RESCUE_PARENT_FORBIDDEN;
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

        else => throw ERROR_UNKNOWN_OP,
    }
}

// =========================== getters ===========================

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
        nextItemIndex: st.mintedCount, // real minted supply; items are hash-addressed (no sequential index)
        content: st.meta.load().collectionContent,
        ownerAddress: st.admin,
    };
}

// TEP-66 royalty getter. 0% (subdomains are utility, not art) but conformant so marketplaces render.
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

get fun get_nft_content(index: int, individualContent: cell): cell {
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

get fun is_locked(): bool {
    return startLoadingCollection().isLocked();
}

get fun dnsresolve(subdomain: slice, _category: int): DnsResolveResponse {
    assert (subdomain.remainingBitsCount() % BYTE_SIZE == 0) throw ERROR_DNS_INVALID_SUBDOMAIN_BITS;

    val startsWithZeroByte = subdomain.preloadInt(BYTE_SIZE) == 0;

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
