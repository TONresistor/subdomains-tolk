import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/errors"
import "@contracts/messages"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "test-utils"

fun expectAdminRefund(
    result: SendResultList,
    collection: address,
    admin: address,
    queryId: uint64,
    balanceBefore: coins,
    revenue: coins = 0,
) {
    expect(result).toHaveSuccessfulTx({ to: collection });
    val refund = result.findTransaction<Excesses>({ from: collection, to: admin });
    expect(refund).toBeNotNull();
    val tx = refund!;
    val msg = tx.loadInMsg<Excesses>();
    expect(tx.loadBody<Excesses>().queryId).toEqual(queryId);
    val info = msg.info;
    match (info) {
        TlbInternalMessage => {
            expect(info.bounce).toEqual(false);
            expect(info.value.grams > revenue + grams("0.045")).toEqual(true);
            expect(info.value.grams < revenue + grams("0.05")).toEqual(true);
        }
        TlbExternalInMessageInfo => throw 0,
        TlbExternalOutMessageInfo => throw 0,
    }
    expect(testing.getAccountBalance(collection)).toEqual(balanceBefore - revenue);
    expect(result.findTransaction({ to: collection })!.outmsgCnt).toEqual(1);
}

fun exerciseAdminSettings(coll: SubdomainCollection, admin: address, user: address) {
    val initial = testing.getAccountBalance(coll.address);
    val revenue = coll.getWithdrawableRevenue();
    val access = coll.sendSetAccessMode(
        admin,
        101,
        ACCESS_ALLOWLIST,
        { value: grams("0.05"), bounce: true },
    );
    expectAdminRefund(access, coll.address, admin, 101, initial);
    expect(coll.getAccessMode()).toEqual(ACCESS_ALLOWLIST);
    val allow = coll.sendSetAllowlistEntry(
        admin,
        102,
        user,
        true,
        { value: grams("0.05"), bounce: true },
    );
    expectAdminRefund(allow, coll.address, admin, 102, initial);
    expect(coll.getIsAllowlisted(user)).toEqual(true);
    val remove = coll.sendSetAllowlistEntry(
        admin,
        103,
        user,
        false,
        { value: grams("0.05"), bounce: true },
    );
    expectAdminRefund(remove, coll.address, admin, 103, initial);
    expect(coll.getIsAllowlisted(user)).toEqual(false);
    val reserve = coll.sendSetLabelReserved(
        admin,
        104,
        labelIndex("reserved"),
        true,
        { value: grams("0.05"), bounce: true },
    );
    expectAdminRefund(reserve, coll.address, admin, 104, initial);
    val unreserve = coll.sendSetLabelReserved(
        admin,
        105,
        labelIndex("reserved"),
        false,
        { value: grams("0.05"), bounce: true },
    );
    expectAdminRefund(unreserve, coll.address, admin, 105, initial);
    expect(coll.getWithdrawableRevenue()).toEqual(revenue);
}

get fun `test admin excesses: Locked settings return funding without touching revenue`() {
    testing.setNow(1700000000);
    val (coll, _parent, admin, user) = deployLockedCollection();
    mintSubdomain(coll, user, "alice", grams("5.07"));
    expect(coll.getWithdrawableRevenue()).toEqual(grams("5"));
    exerciseAdminSettings(coll, admin.address, user.address);
}

get fun `test admin excesses: Linked settings return funding without touching reserves`() {
    testing.setNow(1700000000);
    val (coll, _parent, admin, user) = deployLinkedCollection();
    exerciseAdminSettings(coll, admin.address, user.address);
}

get fun `test admin excesses: pending paid mint remains fully funded`() {
    testing.setNow(1700000000);
    val (coll, _parent, admin, user) = deployLockedCollection();
    val registered = testing.processSingleTraceStep(
        user.address,
        createMessage({
            bounce: true,
            dest: coll.address,
            value: grams("5.07"),
            body: RegisterSubdomain {
                queryId: 11,
                label: labelSlice("alice").toCell(),
                setWalletToMinter: true,
                content: testOnchainMetadata(),
            },
        }),
    );
    expect(coll.getIsMintPending(labelIndex("alice"))).toEqual(true);
    exerciseAdminSettings(coll, admin.address, user.address);
    expect(coll.getIsMintPending(labelIndex("alice"))).toEqual(true);
    expect(coll.getWithdrawableRevenue()).toEqual(0);
    val deploy = registered.outMessages.at<SubdomainInit>(0);
    val initialized = testing.processSingleTraceStep(
        coll.address,
        { messageCell: deploy.toCell() },
    );
    val ready = initialized.outMessages.at<ItemReady>(0);
    net.send(deploy.info.dest, { messageCell: ready.toCell() });
    expect(coll.getWithdrawableRevenue()).toEqual(grams("5"));
    expect(coll.getIsMintPending(labelIndex("alice"))).toEqual(false);
}

get fun `test admin excesses: withdrawal combines exact revenue and refund in one reply`() {
    testing.setNow(1700000000);
    val (coll, _parent, admin, user) = deployLockedCollection();
    mintSubdomain(coll, user, "alice", grams("5.07"));
    val before = testing.getAccountBalance(coll.address);
    val partial = coll.sendWithdrawFees(
        admin.address,
        21,
        grams("2"),
        { value: grams("0.05"), bounce: true },
    );
    expectAdminRefund(
        partial,
        coll.address,
        admin.address,
        21,
        before,
        grams("2"),
    );
    expect(coll.getWithdrawableRevenue()).toEqual(grams("3"));
    val all = coll.sendWithdrawFees(admin.address, 22, 0, { value: grams("0.05"), bounce: true });
    expectAdminRefund(
        all,
        coll.address,
        admin.address,
        22,
        before - grams("2"),
        grams("3"),
    );
    expect(coll.getWithdrawableRevenue()).toEqual(0);
    val empty = coll.sendWithdrawFees(admin.address, 23, 0, { value: grams("0.05"), bounce: true });
    expectAdminRefund(empty, coll.address, admin.address, 23, before - grams("5"));
}

get fun `test admin excesses: rejection never refunds pre-existing funds`() {
    testing.setNow(1700000000);
    val (coll, _parent, admin, user) = deployLockedCollection();
    val before = testing.getAccountBalance(coll.address);
    val unauthorized = coll.sendSetAccessMode(
        user.address,
        31,
        ACCESS_ADMIN_ONLY,
        { value: grams("0.05"), bounce: true },
    );
    expect(unauthorized).toHaveFailedTx({ to: coll.address, exitCode: ERROR_NOT_ADMIN });
    expect(unauthorized.findTransaction<Excesses>({ from: coll.address })).toEqual(null);
    val invalid = coll.sendSetAccessMode(
        admin.address,
        32,
        255,
        { value: grams("0.05"), bounce: true },
    );
    expect(invalid).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INVALID_ACCESS_MODE });
    val dust = coll.sendSetAccessMode(
        admin.address,
        33,
        ACCESS_ADMIN_ONLY,
        { value: 1, bounce: true },
    );
    expect(dust).toHaveTx({ to: coll.address, success: false });
    expect(coll.getAccessMode()).toEqual(ACCESS_PUBLIC);
    expect(testing.getAccountBalance(coll.address)).toBeGreaterOrEqual(before);
}

get fun `test admin excesses: refund action failure rolls back the setting`() {
    testing.setNow(1700000000);
    val (coll, _parent, admin, _user) = deployLockedCollection();
    val probe = coll.sendSetAccessMode(
        admin.address,
        40,
        ACCESS_PUBLIC,
        { value: grams("0.05"), bounce: true },
    );
    expect(probe).toHaveSuccessfulTx({ to: coll.address });
    val probeTx = probe.findTransaction({ to: coll.address })!;
    val description = probeTx.description.load();
    if (description is TlbTransOrd) {
        val compute = description.computePh;
        if (compute is TlbTrComputeVm) {
            val before = testing.getAccountBalance(coll.address);
            val low = coll.sendSetAccessMode(
                admin.address,
                41,
                ACCESS_ADMIN_ONLY,
                { value: compute.gasFees + probeTx.getActionFee()!, bounce: true },
            );
            expect(
                low,
            ).toHaveTx({ to: coll.address, exitCode: 0, actionExitCode: 37, success: false });
            expect(coll.getAccessMode()).toEqual(ACCESS_PUBLIC);
            expect(coll.getWithdrawableRevenue()).toEqual(0);
            expect(testing.getAccountBalance(coll.address)).toBeGreaterOrEqual(before);
            return;
        }
    }
    throw 0;
}

get fun `test admin excesses: zero-revenue Linked claim emits no empty payout`() {
    testing.setNow(1700000000);
    val (coll, parent, admin, _user) = deployLinkedCollection();
    val before = testing.getAccountBalance(coll.address);
    val claim = coll.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 50,
            oldOwnerAddress: admin.address,
            payload: linkedActionPayload(LINKED_ACTION_CLAIM),
        }.toCell(),
        { value: grams("0.05"), bounce: true },
    );
    expect(claim).toHaveSuccessfulTx({ to: coll.address });
    expect(claim.findTransaction({ to: coll.address })!.outmsgCnt).toEqual(1);
    expect(claim.findTransaction({ from: coll.address, to: admin.address })).toEqual(null);
    expect(
        claim.findTransaction<TransferOwnership>({ from: coll.address, to: parent.address }),
    ).toBeNotNull();
    expect(coll.getWithdrawableRevenue()).toEqual(0);
    expect(testing.getAccountBalance(coll.address)).toEqual(before);
}
