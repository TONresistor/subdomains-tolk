// Tier 2: one NFT per subdomain (TEP-62) + DNS resolver.
import "dns-utils"
import "errors"
import "messages"
import "storage"

contract SubdomainItem {
    author: "tolk-subdomains"
    version: "4.0.0"
    description: "Subdomain NFT item (TEP-62) holding its own DNS records."
    incomingMessages: AllowedItemMessage
    storage: ItemStorageInitialized
    storageAtDeployment: ItemStorageNotInitialized
}

type AllowedItemMessage =
    | TransferOwnership
    | EditContent
    | ChangeDnsRecord
    | GetStaticData

fun ItemStorageInitialized.save(self) {
    contract.setData(self.toCell());
}

fun isValidTep62ForwardPayload(payload: TransferForwardPayload): bool {
    val (bits, refs) = payload.remainingBitsAndRefsCount();
    if (bits == 0) {
        return false;
    }
    if (payload.preloadUint(1) == 0) {
        return true;
    }
    return bits == 1 && refs == 1;
}

@inline
fun applyOwnershipTransfer(
    myBalance: coins,
    mutate storage: ItemStorageInitialized,
    queryId: uint64,
    transferData: TransferOwnershipData,
    fwdFees: coins,
) {
    assert (
        isValidTep62ForwardPayload(transferData.forwardPayload)
    ) throw ERROR_INCORRECT_FORWARD_PAYLOAD;

    val newOwnerAddress = transferData.newOwnerAddress;
    newOwnerAddress.forceBasechain();

    val responseDestination = transferData.responseDestination;
    val forwardAmount = transferData.forwardAmount;

    var restAmount = myBalance - MIN_TONS_FOR_STORAGE;
    if (forwardAmount > 0) {
        restAmount -= (forwardAmount + fwdFees);
    }
    val needResponse = responseDestination != null;
    if (needResponse) {
        restAmount -= fwdFees;
    }
    assert (restAmount >= 0) throw ERROR_INSUFFICIENT_BALANCE;

    if (forwardAmount > 0) {
        val assignMsg = createMessage({
            body: OwnershipAssigned {
                queryId,
                oldOwnerAddress: storage.ownerAddress,
                payload: transferData.forwardPayload,
            },
            bounce: false,
            dest: newOwnerAddress,
            value: forwardAmount,
        });
        assignMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
    }

    if (needResponse) {
        responseDestination!.forceBasechain();
        val excessesMsg = createMessage({
            body: Excesses { queryId },
            bounce: false,
            dest: responseDestination!,
            value: restAmount,
        });
        excessesMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
    }

    storage.ownerAddress = newOwnerAddress;
    storage.lastTouch = blockchain.now();
    storage.save();
}

// Every outbound item message is deliberately non-bounceable: ownership notifications and
// excesses are best-effort standard replies, so there is no item state to roll back on failure.
fun onBouncedMessage(_in: InMessageBounced) {}

fun onInternalMessage(in: InMessage) {
    val loading = startLoadingItemStorage();

    // ---------------- INIT ----------------
    if (!loading.isInitialized()) {
        val uninit = loading.parseNotInitialized();
        assert (in.senderAddress == uninit.collectionAddress) throw ERROR_NOT_FROM_COLLECTION;

        val init = lazy SubdomainInit.fromSlice(
            in.body,
            { throwIfOpcodeDoesNotMatch: ERROR_UNKNOWN_OP },
        );
        init.minter.forceBasechain();

        assert (init.index == uninit.index) throw ERROR_INDEX_MISMATCH;
        assert (init.label.load().hash() == uninit.index) throw ERROR_INDEX_MISMATCH;

        var records: DnsRecords = [];
        if (init.setWalletToMinter) {
            records.set(CAT_WALLET, buildWalletRecord(init.minter));
        }

        val now = blockchain.now();
        val initStorage: ItemStorageInitialized = {
            index: uninit.index,
            collectionAddress: uninit.collectionAddress,
            ownerAddress: init.minter,
            records: records.toCell(),
            label: init.label,
            mintedAt: now,
            lastTouch: now,
            validUntil: 0,
        };
        initStorage.save();
        val ready = createMessage({
            bounce: BounceMode.NoBounce,
            dest: uninit.collectionAddress,
            value: ITEM_READY_VALUE,
            body: ItemReady {
                queryId: init.queryId,
                index: init.index,
                minter: init.minter,
            },
        });
        ready.send(SEND_MODE_PAY_FEES_SEPARATELY);
        return;
    }

    var storage = loading.parseInitialized();

    if (in.body.isEmpty()) {
        return;
    }

    if (in.body.remainingBitsCount() >= 32 && in.body.preloadUint(32) == 0xd53276db) {
        return;
    }

    var msg = lazy AllowedItemMessage.fromSlice(in.body);

    match (msg) {
        TransferOwnership => {
            assert (in.senderAddress == storage.ownerAddress) throw ERROR_NOT_OWNER;
            applyOwnershipTransfer(
                contract.getOriginalBalance(),
                mutate storage,
                msg.queryId,
                msg.transferData,
                in.originalForwardFee,
            );
        }

        EditContent => {
            assert (in.senderAddress == storage.ownerAddress) throw ERROR_NOT_OWNER;
            val validated = msg.newContent.load();
            storage.records = validated.toCell();
            storage.lastTouch = blockchain.now();
            storage.save();
        }

        ChangeDnsRecord => {
            assert (in.senderAddress == storage.ownerAddress) throw ERROR_NOT_OWNER;
            var dnsRecords = storage.records.load();
            if (msg.value.remainingRefsCount() > 0) {
                dnsRecords.set(msg.key, msg.value.loadRef());
            } else {
                dnsRecords.delete(msg.key);
            }
            storage.records = dnsRecords.toCell();
            storage.lastTouch = blockchain.now();
            storage.save();
        }

        GetStaticData => {
            val responseMsg = createMessage({
                body: ReportStaticData {
                    queryId: msg.queryId,
                    itemIndex: storage.index,
                    collectionAddress: storage.collectionAddress,
                },
                bounce: false,
                dest: in.senderAddress,
                value: 0,
            });
            responseMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        else => throw ERROR_UNKNOWN_OP,
    }
}

// =========================== getters ===========================

get fun get_nft_data(): ItemNftDataReply {
    val loading = startLoadingItemStorage();
    if (!loading.isInitialized()) {
        val st = loading.parseNotInitialized();
        return {
            isInitialized: false,
            index: st.index,
            collectionAddress: st.collectionAddress,
            ownerAddress: null,
            content: null,
        };
    }
    val st = loading.parseInitialized();
    return {
        isInitialized: true,
        index: st.index,
        collectionAddress: st.collectionAddress,
        ownerAddress: st.ownerAddress,
        content: st.label as cell,
    };
}

get fun get_editor(): address? {
    val loading = startLoadingItemStorage();
    if (!loading.isInitialized()) {
        return null;
    }
    return loading.parseInitialized().ownerAddress;
}

get fun get_domain(): slice {
    val loading = startLoadingItemStorage();
    if (!loading.isInitialized()) {
        return beginCell().endCell().beginParse();
    }
    return loading.parseInitialized().label.load();
}

get fun get_minted_at(): int {
    val loading = startLoadingItemStorage();
    return loading.isInitialized() ? loading.parseInitialized().mintedAt : 0;
}

get fun get_last_touch(): int {
    val loading = startLoadingItemStorage();
    return loading.isInitialized() ? loading.parseInitialized().lastTouch : 0;
}

get fun get_valid_until(): int {
    val loading = startLoadingItemStorage();
    return loading.isInitialized() ? loading.parseInitialized().validUntil : 0;
}

get fun dnsresolve(subdomain: slice, category: uint256): DnsResolveResponse {
    val subdomainBits = subdomain.remainingBitsCount();
    assertDnsQueryStartsWithZero(subdomain);

    val loading = startLoadingItemStorage();
    if (!loading.isInitialized()) {
        return { resolvedPrefixLengthBits: 0, resolvedRecord: null };
    }
    val st = loading.parseInitialized();
    val dnsRecord = st.records.load();

    if (subdomainBits > BYTE_SIZE) {
        category = CAT_DNS_NEXT_RESOLVER;
    }

    if (category == 0) {
        return { resolvedPrefixLengthBits: BYTE_SIZE, resolvedRecord: dnsRecord.toLowLevelDict() };
    }

    val value = dnsRecord.get(category);
    if (!value.isFound) {
        return { resolvedPrefixLengthBits: BYTE_SIZE, resolvedRecord: null };
    }
    return { resolvedPrefixLengthBits: BYTE_SIZE, resolvedRecord: value.loadValue() };
}
