// Funding-exactness tests for the 1-tx create flow (regression for a mainnet action-phase-37 failure).
// The factory must work with a near-zero own balance and an inbound value at the exact minimum;
// every nanoton of the flow must come from the create message itself, explicitly budgeted.
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/tlb/either"
import "@acton/types/transaction"
import "@contracts/messages"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "@wrappers/SubdomainFactory.gen"
import "test-utils"

fun createPayload(): RemainingBitsAndRefs {
    return beginCell().storeRef(makeMeta().toCell()).endCell().beginParse();
}

// Regression for the old mainnet action-phase-37 failure: a thin factory must never strand the NFT.
// The legacy 0.4 TON frontend funding remains above the reduced v4 exact minimum.
get fun `test funding: thin factory and legacy 0.4 inbound complete safely`() {
    val owner = newActor("ofo");
    val parent = newActor("ofp");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(
        owner.address,
        { value: ton("0.1"), bounce: false },
    ); // mainnet-like thin balance

    val res = factory.sendOwnershipAssigned(
        parent.address,
        1,
        owner.address,
        createPayload(),
        { value: ton("0.4"), bounce: false },
    );
    // whatever happens, the factory must emit a TransferOwnership (create hand-off or refund)
    expect(res).toHaveSuccessfulTx({ to: factory.address });
    expect(
        res.findTransaction<TransferOwnership>({ from: factory.address, to: parent.address }),
    ).toBeNotNull();
    expect(res.findTransaction({ from: factory.address, deploy: true })).toBeNotNull();
}

get fun `test funding: one nanotON below the Locked create minimum returns the parent`() {
    val owner = newActor("locked-boundary-owner");
    val parent = newActor("locked-boundary-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("0.01"), bounce: false });

    val res = factory.sendOwnershipAssigned(
        parent.address,
        1,
        owner.address,
        createPayload(),
        { value: MIN_CREATE_VALUE - 1, bounce: false },
    );
    expect(res).toHaveSuccessfulTx({ to: factory.address });
    expect(
        res.findTransaction<TransferOwnership>({ from: factory.address, to: parent.address }),
    ).toBeNotNull();
    expect(res.findTransaction({ from: factory.address, deploy: true })).toEqual(null);
}

get fun `test funding: rejected custody returns immediately at its exact safety boundary`() {
    val owner = newActor("rejected-boundary-owner");
    val lowParent = newActor("rejected-boundary-low-parent");
    val exactParent = newActor("rejected-boundary-exact-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("0.1"), bounce: false });
    val junk = beginCell().storeRef(beginCell().storeUint(1, 1).endCell()).endCell().beginParse();

    val low = testing.processSingleTraceStep(
        lowParent.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: MIN_REJECTED_RETURN_VALUE - 1,
            body: OwnershipAssigned {
                queryId: 2,
                oldOwnerAddress: owner.address,
                payload: junk,
            },
        }),
    );
    expect(low.outMessages.size()).toEqual(0);

    val exact = testing.processSingleTraceStep(
        exactParent.address,
        createMessage({
            bounce: false,
            dest: factory.address,
            value: MIN_REJECTED_RETURN_VALUE,
            body: OwnershipAssigned {
                queryId: 3,
                oldOwnerAddress: owner.address,
                payload: junk,
            },
        }),
    );
    expect(exact.outMessages.size()).toEqual(1);
    expect(exact.outMessages.at<TransferOwnership>(0).info.dest).toEqual(exactParent.address);
}

// The real worst case: factory's own balance nearly exhausted by storage and the inbound is the
// exact documented minimum; the full create must still succeed end-to-end.
get fun `test funding: create succeeds at exact minimum with a dust factory balance`() {
    val owner = newActor("ofo2");
    val parent = newActor("ofp2");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("0.01"), bounce: false }); // dust own balance

    val expectedColl = factory.getCollectionAddress(parent.address);
    val res = factory.sendOwnershipAssigned(
        parent.address,
        1,
        owner.address,
        createPayload(),
        { value: MIN_CREATE_VALUE, bounce: false }, // exact minimum
    );
    expect(res).toHaveSuccessfulTx({ to: factory.address });

    // collection deployed + locked + correctly funded above its storage floor
    val deployTx = res.findTransaction({ from: factory.address, deploy: true });
    expect(deployTx).toBeNotNull();
    expect(deployTx!.getAccountAddress()).toEqual(expectedColl);
    val coll = SubdomainCollection.fromAddress(expectedColl);
    expect(coll.isLocked()).toEqual(true);
    expect(coll.getAdmin()).toEqual(owner.address);
    expect(coll.getPrice(5)).toEqual(ton("5")); // meta (price grid) parsed and live
    expect(testing.getAccountBalance(coll.address)).toBeGreater(
        testing.getAccountStorageFee(coll.address, 10 * 365 * 24 * 60 * 60)!,
    );

    // the .ton hand-off left the factory
    expect(
        res.findTransaction<TransferOwnership>({ from: factory.address, to: parent.address }),
    ).toBeNotNull();
}

// Garbage config payload (unparseable meta) must take the refund path, never throw
// (a throw in compute aborts the tx and strands the NFT, the failure's other landmine).
get fun `test funding: garbage meta payload refunds the .ton instead of stranding it`() {
    val owner = newActor("ofo3");
    val parent = newActor("ofp3");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("0.1"), bounce: false });

    // a ref that is NOT a CollectionMeta (no 3 sub-refs)
    val junk = beginCell().storeRef(beginCell().storeUint(42, 32).endCell()).endCell().beginParse();
    val res = factory.sendOwnershipAssigned(
        parent.address,
        1,
        owner.address,
        junk,
        { value: ton("1"), bounce: false },
    );
    expect(res).toHaveSuccessfulTx({ to: factory.address });
    // refunded, nothing deployed
    expect(
        res.findTransaction<TransferOwnership>({ from: factory.address, to: parent.address }),
    ).toBeNotNull();
    expect(res.findTransaction({ from: factory.address, deploy: true })).toEqual(null);
}

get fun `test funding: rejected custody does not retain caller metadata`() {
    val owner = newActor("bounded-return-owner");
    val parent = newActor("bounded-return-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("0.1"), bounce: false });
    val cellsBefore = testing.getAccountState(factory.address)!.storageStat.used.cells;

    var amplified = beginCell().storeUint(0, 1).endCell();
    repeat (64) {
        amplified = beginCell().storeUint(0, 1).storeRef(amplified).endCell();
    }
    val payload = beginCell().storeRef(amplified).endCell().beginParse();
    val rejected = factory.sendOwnershipAssigned(
        parent.address,
        10,
        owner.address,
        payload,
        { value: ton("1"), bounce: false },
    );
    expect(rejected).toHaveSuccessfulTx({ to: factory.address });
    expect(testing.getAccountState(factory.address)!.storageStat.used.cells).toBeLessOrEqual(
        cellsBefore + 8,
    );

    val returned = rejected.findTransaction<TransferOwnership>({
        from: factory.address,
        to: parent.address,
    })!;
    val returnEither = returned.loadInMsg<TransferOwnership>().body;
    val returnBody = match (returnEither) {
        TlbEitherLeft => returnEither.value,
        TlbEitherRight => returnEither.value.load(),
    };
    val acknowledged = factory.sendAny(
        parent.address,
        Excesses { queryId: returnBody.queryId }.toCell(),
        { value: ton("0.05"), bounce: false },
    );
    expect(acknowledged).toHaveSuccessfulTx({ to: factory.address });
    expect(testing.getAccountState(factory.address)!.storageStat.used.cells).toBeLessOrEqual(
        cellsBefore + 1,
    );
}

get fun `test funding: a later valid parent transfer replaces a stale rejection receipt`() {
    val owner = newActor("stale-return-owner");
    val parent = newActor("stale-return-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("0.1"), bounce: false });

    val junk = beginCell().storeRef(beginCell().storeUint(7, 3).endCell()).endCell().beginParse();
    factory.sendOwnershipAssigned(
        parent.address,
        20,
        owner.address,
        junk,
        { value: ton("1"), bounce: false },
    );

    val recovered = factory.sendOwnershipAssigned(
        parent.address,
        21,
        owner.address,
        createPayload(),
        { value: MIN_CREATE_VALUE, bounce: false },
    );
    expect(recovered).toHaveSuccessfulTx({
        from: factory.address,
        to: factory.getCollectionAddress(parent.address),
        deploy: true,
    });
}
