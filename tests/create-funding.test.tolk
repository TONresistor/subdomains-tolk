// Funding-exactness tests for the 1-tx create flow (regression for a mainnet action-phase-37 failure).
// The factory must work with a near-zero own balance and an inbound value at the exact minimum;
// every nanoton of the flow must come from the create message itself, explicitly budgeted.
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "test-utils"
import "../contracts/messages"
import "../contracts/storage"
import "../wrappers/SubdomainCollection.gen"
import "../wrappers/SubdomainFactory.gen"

fun createPayload(): RemainingBitsAndRefs {
    return beginCell().storeRef(makeMeta().toCell()).endCell().beginParse();
}

// Reproduction of the mainnet failure: thin factory balance (0.1) + the dApp's old forward (0.4).
// Pre-fix this died in the action phase (code 37) stranding the NFT. Post-fix the guard refunds
// instead (0.4 < MIN_CREATE_VALUE); the .ton always leaves the factory in the same transaction.
get fun `test funding: mainnet repro - thin factory + 0.4 inbound never strands the NFT`() {
    val owner = newActor("ofo");
    val parent = newActor("ofp");
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0 });
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
}

// The real worst case: factory's own balance nearly exhausted by storage and the inbound is the
// exact documented minimum; the full create must still succeed end-to-end.
get fun `test funding: create succeeds at exact minimum with a dust factory balance`() {
    val owner = newActor("ofo2");
    val parent = newActor("ofp2");
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0 });
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

    // the .ton hand-off left the factory
    expect(
        res.findTransaction<TransferOwnership>({ from: factory.address, to: parent.address }),
    ).toBeNotNull();
    expect(factory.getDeployedCount()).toEqual(1);
}

// Garbage config payload (unparseable meta) must take the refund path, never throw
// (a throw in compute aborts the tx and strands the NFT, the failure's other landmine).
get fun `test funding: garbage meta payload refunds the .ton instead of stranding it`() {
    val owner = newActor("ofo3");
    val parent = newActor("ofp3");
    val factory = SubdomainFactory.fromStorage({ deployedCount: 0 });
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
    expect(factory.getDeployedCount()).toEqual(0);
}
