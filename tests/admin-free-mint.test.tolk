import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/testing/fuzz"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/dns-utils"
import "@contracts/errors"
import "@contracts/messages"
import "@contracts/metadata"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "@wrappers/SubdomainItem.gen"
import "test-utils"

fun adminMintFixture(isLinked: bool, autoRenew: bool): (
    SubdomainCollection,
    Treasury,
    Treasury,
    Treasury,
) {
    val master = newActor("admin-review-master");
    val parent = newActor("admin-review-parent");
    val admin = newActor("admin-review-admin");
    val user = newActor("admin-review-user");
    val coll = SubdomainCollection.fromStorage({
        master: master.address,
        parentDomain: parent.address,
        isLinked,
        linkedAdmin: isLinked ? admin.address : master.address,
    });
    coll.deploy(master.address, { value: grams("0.05"), bounce: false });
    var meta = makeMeta();
    meta.autoRenewParent = autoRenew;
    val locked = coll.sendAny(
        master.address,
        LockCollection {
            queryId: 1,
            parentDomain: parent.address,
            admin: admin.address,
            isLinked,
            meta: meta.toCell(),
        }.toCell(),
        { value: grams("0.15"), bounce: false },
    );
    expect(locked).toHaveSuccessfulTx({ to: coll.address });
    return (coll, parent, admin, user);
}

fun adminLabel(charCount: int): slice {
    var label = beginCell();
    repeat (charCount) {
        label.storeUint(97, BYTE_SIZE);
    }
    return label.endCell().beginParse();
}

fun adminBounce(original: cell): cell {
    val info: RichBounceOriginalMsgInfo = {
        valueCoins: ITEM_DEPLOY_COST,
        valueExtra: [],
        createdLt: 0,
        createdAt: 0,
    };
    return RichBounceBody {
        originalBody: original,
        originalInfo: info.toCell(),
        bouncedByPhase: 1,
        exitCode: ERROR_UNKNOWN_OP,
        computePhase: null,
    }.toCell();
}

get fun `test admin free: exact due renewal funding and one nanotON boundary`() {
    testing.setNow(1700000000);
    val (coll, parent, admin, _user) = adminMintFixture(false, true);
    testing.setNow(1700000000 + PARENT_HEARTBEAT_INTERVAL + 1);
    val quote = coll.getMintQuote(admin.address, 5);
    expect(quote.effectivePrice).toEqual(0);
    expect(quote.requiredValue).toEqual(
        ITEM_DEPLOY_COST + MINT_FEE_BUFFER + PARENT_HEARTBEAT_AMOUNT,
    );
    val denied = coll.sendRegisterSubdomain(
        admin.address,
        1,
        labelSlice("alice"),
        true,
        testOnchainMetadata(),
        { value: quote.requiredValue - 1, bounce: true },
    );
    expect(denied).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_MINT_VALUE });
    expect(coll.getIsMintPending(labelIndex("alice"))).toEqual(false);
    val before = testing.getAccountBalance(coll.address);
    val (item, res) = mintSubdomain(coll, admin, "alice", quote.requiredValue);
    expect(item.getNftData().ownerAddress).toEqual(admin.address);
    expect(res.findTransaction({ from: coll.address, to: parent.address })).toBeNotNull();
    expect(res.findTransaction({ from: coll.address, to: admin.address })).toEqual(null);
    expect(coll.getWithdrawableRevenue()).toEqual(0);
    expect(testing.getAccountBalance(coll.address)).toBeGreaterOrEqual(before);
    expect(coll.getMintQuote(admin.address, 5).requiredValue).toEqual(
        ITEM_DEPLOY_COST + MINT_FEE_BUFFER,
    );
}

get fun `test admin free: repeated exact mints preserve collection balance`() {
    val (coll, _parent, admin, _user) = adminMintFixture(false, false);
    val before = testing.getAccountBalance(coll.address);
    repeat (20) {
        val n = coll.getMintedCount();
        val label = beginCell()
            .storeUint(0x61616161, 32)
            .storeUint(97 + n, BYTE_SIZE)
            .endCell()
            .beginParse();
        val res = coll.sendRegisterSubdomain(
            admin.address,
            n,
            label,
            true,
            testOnchainMetadata(),
            { value: coll.getMintQuote(admin.address, 5).requiredValue, bounce: true },
        );
        expect(res).toHaveSuccessfulTx({ from: coll.address, deploy: true });
        expect(coll.getMintedCount()).toEqual(n + 1);
        expect(coll.getWithdrawableRevenue()).toEqual(0);
        expect(testing.getAccountBalance(coll.address)).toBeGreaterOrEqual(before);
    }
}

get fun `test admin free: reserved names remain protected and labels remain validated`() {
    val (coll, _parent, admin, user) = deployLockedCollection();
    val reserved = coll.sendSetLabelReserved(
        admin.address,
        1,
        labelIndex("alice"),
        true,
        { value: grams("0.05"), bounce: true },
    );
    expect(reserved).toHaveSuccessfulTx({ to: coll.address });
    val denied = coll.sendRegisterSubdomain(
        user.address,
        2,
        labelSlice("alice"),
        true,
        testOnchainMetadata(),
        { value: grams("10"), bounce: true },
    );
    expect(denied).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_RESERVED });
    mintSubdomain(coll, admin, "alice", coll.getMintQuote(admin.address, 5).requiredValue);
    val duplicate = coll.sendRegisterSubdomain(
        admin.address,
        3,
        labelSlice("alice"),
        true,
        testOnchainMetadata(),
        { value: grams("1"), bounce: true },
    );
    expect(duplicate).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_TAKEN });
    val short = coll.sendRegisterSubdomain(
        admin.address,
        4,
        labelSlice("abc"),
        true,
        testOnchainMetadata(),
        { value: grams("1"), bounce: true },
    );
    expect(short).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_TOO_SHORT });
    val invalid = coll.sendRegisterSubdomain(
        admin.address,
        5,
        labelSlice("-bad-"),
        true,
        testOnchainMetadata(),
        { value: grams("1"), bounce: true },
    );
    expect(invalid).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_INVALID_CHARS });
    expect(coll.getMintQuote(admin.address, 3).allowed).toEqual(false);
    expect(coll.getMintQuote(admin.address, MAX_DOMAIN_SIZE + 1).allowed).toEqual(false);
    expect(coll.getMintedCount()).toEqual(1);
}

get fun `test admin free: delayed acknowledgement retains price across admin transfer`() {
    val (coll, _parent, admin, user) = deployLockedCollection();
    val request = createMessage({
        bounce: true,
        dest: coll.address,
        value: coll.getMintQuote(admin.address, 5).requiredValue,
        body: RegisterSubdomain {
            queryId: 88,
            label: labelSlice("alice").toCell(),
            setWalletToMinter: true,
            content: testOnchainMetadata(),
        },
    });
    val registered = testing.processSingleTraceStep(admin.address, request);
    val deploy = registered.outMessages.at<SubdomainInit>(0);
    val initialized = testing.processSingleTraceStep(
        coll.address,
        { messageCell: deploy.toCell() },
    );
    expect(coll.getIsMintPending(labelIndex("alice"))).toEqual(true);
    val duplicate = coll.sendRegisterSubdomain(
        admin.address,
        89,
        labelSlice("alice"),
        true,
        testOnchainMetadata(),
        { value: grams("1"), bounce: true },
    );
    expect(duplicate).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_TAKEN });
    val transfer = coll.sendTransferAdmin(
        admin.address,
        90,
        user.address,
        { value: grams("0.1"), bounce: true },
    );
    expect(transfer).toHaveSuccessfulTx({ to: coll.address });
    val ready = initialized.outMessages.at<ItemReady>(0);
    net.send(deploy.info.dest, { messageCell: ready.toCell() });
    expect(coll.getMintedCount()).toEqual(1);
    expect(coll.getWithdrawableRevenue()).toEqual(0);
    net.send(deploy.info.dest, { messageCell: ready.toCell() });
    expect(coll.getMintedCount()).toEqual(1);
    expect(coll.getWithdrawableRevenue()).toEqual(0);
    expect(coll.getMintQuote(admin.address, 5).effectivePrice).toEqual(grams("5"));
}

get fun `test admin free: lost callback recovers zero price via ConfirmMint`() {
    val (coll, _parent, admin, user) = deployLockedCollection();
    val registered = testing.processSingleTraceStep(
        admin.address,
        createMessage({
            bounce: true,
            dest: coll.address,
            value: coll.getMintQuote(admin.address, 5).requiredValue,
            body: RegisterSubdomain {
                queryId: 88,
                label: labelSlice("alice").toCell(),
                setWalletToMinter: true,
                content: testOnchainMetadata(),
            },
        }),
    );
    val deploy = registered.outMessages.at<SubdomainInit>(0);
    testing.processSingleTraceStep(coll.address, { messageCell: deploy.toCell() });
    val recovered = coll.sendConfirmMint(
        user.address,
        89,
        labelIndex("alice"),
        { value: MIN_CONFIRM_MINT_VALUE, bounce: true },
    );
    expect(recovered).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getIsMintPending(labelIndex("alice"))).toEqual(false);
    expect(coll.getMintedCount()).toEqual(1);
    expect(coll.getWithdrawableRevenue()).toEqual(0);
}

get fun `test admin free: bounce refunds only returned funding to the original admin`() {
    val (coll, _parent, admin, user) = deployLockedCollection();
    mintSubdomain(coll, user, "bobby", coll.getMintQuote(user.address, 5).requiredValue);
    val registered = testing.processSingleTraceStep(
        admin.address,
        createMessage({
            bounce: true,
            dest: coll.address,
            value: coll.getMintQuote(admin.address, 5).requiredValue,
            body: RegisterSubdomain {
                queryId: 88,
                label: labelSlice("alice").toCell(),
                setWalletToMinter: true,
                content: testOnchainMetadata(),
            },
        }),
    );
    val deploy = registered.outMessages.at<SubdomainInit>(0);
    coll.sendTransferAdmin(admin.address, 90, user.address, { value: grams("0.1"), bounce: true });
    val bounced = createMessage({
        bounce: false,
        dest: coll.address,
        value: grams("0.055"),
        body: adminBounce(deploy.loadBody().toCell()),
    }).bounced();
    val rolledBack = testing.processSingleTraceStep(deploy.info.dest, bounced);
    val refund = rolledBack.outMessages.at<Excesses>(0);
    expect(refund.info.dest).toEqual(admin.address);
    expect(refund.info.value.grams).toEqual(grams("0.055"));
    expect(coll.getIsMintPending(labelIndex("alice"))).toEqual(false);
    expect(coll.getMintedCount()).toEqual(1);
    expect(coll.getWithdrawableRevenue()).toEqual(grams("5"));
    val replay = testing.processSingleTraceStep(deploy.info.dest, bounced);
    expect(replay.outMessages.size()).toEqual(0);
    val retry = coll.sendRegisterSubdomain(
        admin.address,
        91,
        labelSlice("alice"),
        true,
        testOnchainMetadata(),
        { value: ITEM_DEPLOY_COST + MINT_FEE_BUFFER, bounce: true },
    );
    expect(retry).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_MINT_VALUE });
    mintSubdomain(coll, user, "alice", coll.getMintQuote(user.address, 5).requiredValue);
    expect(coll.getWithdrawableRevenue()).toEqual(grams("5"));
}

get fun `test admin free: Linked exemption follows authenticated parent claim`() {
    val (coll, parent, admin, user) = deployLinkedCollection();
    val denied = coll.sendAny(
        user.address,
        OwnershipAssigned {
            queryId: 1,
            oldOwnerAddress: user.address,
            payload: linkedActionPayload(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: grams("0.05"), bounce: false },
    );
    expect(denied).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getAdmin()).toEqual(admin.address);
    val claim = coll.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 2,
            oldOwnerAddress: user.address,
            payload: linkedActionPayload(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: grams("0.05"), bounce: false },
    );
    expect(claim).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getAdmin()).toEqual(user.address);
    expect(coll.getMintQuote(admin.address, 5).effectivePrice).toEqual(grams("5"));
    expect(coll.getMintQuote(user.address, 5).effectivePrice).toEqual(0);
    val (_item, minted) = mintSubdomain(
        coll,
        user,
        "alice",
        coll.getMintQuote(user.address, 5).requiredValue,
    );
    expect(minted.findTransaction({ from: coll.address, to: parent.address })).toEqual(null);
    expect(coll.getWithdrawableRevenue()).toEqual(0);
}

get fun `test admin free: allowlisted users still pay while admins bypass every access mode`() {
    val (coll, _parent, admin, user) = deployLockedCollection();
    coll.sendSetAllowlistEntry(
        admin.address,
        1,
        user.address,
        true,
        { value: grams("0.05"), bounce: true },
    );
    coll.sendSetAccessMode(
        admin.address,
        2,
        ACCESS_ALLOWLIST,
        { value: grams("0.05"), bounce: true },
    );
    val quote = coll.getMintQuote(user.address, 5);
    expect(quote.allowed).toEqual(true);
    expect(quote.effectivePrice).toEqual(grams("5"));
    val denied = coll.sendRegisterSubdomain(
        user.address,
        3,
        labelSlice("alice"),
        true,
        testOnchainMetadata(),
        { value: ITEM_DEPLOY_COST + MINT_FEE_BUFFER, bounce: true },
    );
    expect(denied).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_MINT_VALUE });
    mintSubdomain(coll, user, "alice", quote.requiredValue);
    mintSubdomain(coll, admin, "bobby", coll.getMintQuote(admin.address, 5).requiredValue);
    coll.sendSetAccessMode(
        admin.address,
        4,
        ACCESS_ADMIN_ONLY,
        { value: grams("0.05"), bounce: true },
    );
    mintSubdomain(coll, admin, "carol", coll.getMintQuote(admin.address, 5).requiredValue);
    expect(coll.getWithdrawableRevenue()).toEqual(grams("5"));
}

get fun `test admin free: a paid pending mint stays paid when its buyer becomes admin`() {
    val (coll, _parent, admin, user) = deployLockedCollection();
    val registered = testing.processSingleTraceStep(
        user.address,
        createMessage({
            bounce: true,
            dest: coll.address,
            value: coll.getMintQuote(user.address, 5).requiredValue,
            body: RegisterSubdomain {
                queryId: 88,
                label: labelSlice("alice").toCell(),
                setWalletToMinter: true,
                content: testOnchainMetadata(),
            },
        }),
    );
    val deploy = registered.outMessages.at<SubdomainInit>(0);
    val initialized = testing.processSingleTraceStep(
        coll.address,
        { messageCell: deploy.toCell() },
    );
    coll.sendTransferAdmin(admin.address, 90, user.address, { value: grams("0.1"), bounce: true });
    val ready = initialized.outMessages.at<ItemReady>(0);
    net.send(deploy.info.dest, { messageCell: ready.toCell() });
    expect(coll.getMintedCount()).toEqual(1);
    expect(coll.getWithdrawableRevenue()).toEqual(grams("5"));
    expect(coll.getMintQuote(user.address, 5).effectivePrice).toEqual(0);
}

get fun `test admin free: maximum label and near-limit metadata fit exact funding`() {
    testing.setNow(1700000000);
    val (coll, parent, admin, _user) = adminMintFixture(false, true);
    testing.setNow(1700000000 + PARENT_HEARTBEAT_INTERVAL + 1);
    var tail = beginCell()
        .storeUint(0, 250)
        .storeUint(0, 250)
        .storeUint(0, 250)
        .storeUint(0, 250)
        .endCell();
    repeat (14) {
        tail = beginCell()
            .storeUint(0, 250)
            .storeUint(0, 250)
            .storeUint(0, 250)
            .storeUint(0, 250)
            .storeRef(tail)
            .endCell();
    }
    var fields: map<uint256, cell> = [];
    fields.set(
        "name".sha256(),
        beginCell()
            .storeUint(0, 8)
            .storeUint(0, 248)
            .storeUint(0, 248)
            .storeUint(0, 248)
            .storeUint(0, 248)
            .storeRef(tail)
            .endCell(),
    );
    val content = beginCell().storeUint(0, 8).storeDict(fields.toLowLevelDict()).endCell();
    val (_cells, bits, _refs, complete) = content.calculateSize(MAX_METADATA_CELLS);
    expect(complete).toEqual(true);
    expect(bits! > MAX_METADATA_BITS - 500 && bits! <= MAX_METADATA_BITS).toEqual(true);
    var labelBuilder = beginCell().storeUint(120, BYTE_SIZE);
    repeat (MAX_DOMAIN_SIZE - 2) {
        labelBuilder.storeUint(45, BYTE_SIZE);
    }
    labelBuilder.storeUint(120, BYTE_SIZE);
    val label = labelBuilder.endCell().beginParse();
    coll.sendAny(admin.address, beginCell().endCell(), { value: grams("0.01"), bounce: false });
    val before = testing.getAccountBalance(coll.address);
    val quote = coll.getMintQuote(admin.address, MAX_DOMAIN_SIZE);
    val minted = coll.sendRegisterSubdomain(
        admin.address,
        1,
        label,
        true,
        content,
        { value: quote.requiredValue, bounce: true },
    );
    expect(minted).toHaveSuccessfulTx({ from: coll.address, deploy: true });
    expect(coll.getMintedCount()).toEqual(1);
    expect(coll.getWithdrawableRevenue()).toEqual(0);
    expect(coll.getIsMintPending(label.hash())).toEqual(false);
    expect(minted.findTransaction({ from: coll.address, to: parent.address })).toBeNotNull();
    expect(testing.getAccountBalance(coll.address)).toBeGreaterOrEqual(before);
}

@test.fuzz({ runs: 64, seed: 20261008 })
get fun `test admin free: fuzz authorization pricing refunds and reserve`(
    linked: bool,
    renew: bool,
    due: bool,
    isAdmin: bool,
    rawMode: uint8,
    rawLength: uint8,
    rawSurplus: uint32,
) {
    testing.setNow(1700000000);
    val (coll, parent, admin, user) = adminMintFixture(linked, renew);
    val mode = fuzz.bound(rawMode as int, 0, 2) as uint8;
    val length = fuzz.bound(rawLength as int, 4, MAX_DOMAIN_SIZE);
    val surplus = fuzz.bound(rawSurplus as int, 0, grams("0.2"));
    coll.sendSetAccessMode(admin.address, 1, mode, { value: grams("0.05"), bounce: true });
    if (due) {
        testing.setNow(1700000000 + PARENT_HEARTBEAT_INTERVAL + 1);
    }
    val minter = isAdmin ? admin : user;
    val quote = coll.getMintQuote(minter.address, length);
    expect(quote.allowed).toEqual(isAdmin || mode == ACCESS_PUBLIC);
    val price: coins = isAdmin ? 0 : coll.getPrice(length);
    val heartbeat = due && renew && !linked;
    val buffer = length > LONG_LABEL_THRESHOLD ? LONG_LABEL_MINT_FEE_BUFFER : MINT_FEE_BUFFER;
    val funding = ITEM_DEPLOY_COST + buffer + (heartbeat ? PARENT_HEARTBEAT_AMOUNT : 0 as coins);
    expect(quote.effectivePrice).toEqual(price);
    expect(quote.requiredValue).toEqual(price + funding);
    val balance = testing.getAccountBalance(coll.address);
    val minted = coll.sendRegisterSubdomain(
        minter.address,
        2,
        adminLabel(length),
        true,
        testOnchainMetadata(),
        { value: quote.requiredValue + surplus, bounce: true },
    );
    if (!quote.allowed) {
        expect(minted).toHaveFailedTx({ to: coll.address, exitCode: ERROR_MINT_NOT_ALLOWED });
        expect(coll.getMintedCount()).toEqual(0);
        return;
    }
    expect(minted).toHaveSuccessfulTx({ from: coll.address, deploy: true });
    expect(coll.getMintedCount()).toEqual(1);
    expect(coll.getWithdrawableRevenue()).toEqual(price);
    expect(testing.getAccountBalance(coll.address)).toBeGreaterOrEqual(balance + price);
    expect(minted.findTransaction({ from: coll.address, to: parent.address }) != null).toEqual(
        heartbeat,
    );
    val refund = minted.findTransaction<Excesses>({ from: coll.address, to: minter.address });
    if (surplus == 0) {
        expect(refund).toEqual(null);
    } else {
        expect(refund).toBeNotNull();
        val message = refund!.loadInMsg<Excesses>();
        val info = message.info;
        match (info) {
            TlbInternalMessage => expect(info.value.grams).toEqual(surplus),
            TlbExternalInMessageInfo => throw 0,
            TlbExternalOutMessageInfo => throw 0,
        }
    }
}
