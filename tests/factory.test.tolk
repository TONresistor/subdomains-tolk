import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/tlb/either"
import "@acton/types/transaction"
import "@contracts/messages"
import "@wrappers/SubdomainCollection.gen"
import "@wrappers/SubdomainFactory.gen"
import "test-utils"

// 1-tx create: a `.ton` transferred in to the factory (carrying a config payload) deploys a
// locked collection at the deterministic address and hands the `.ton` over to it, all in one transaction.
get fun `test factory: create deploys a locked collection + hands off the .ton`() {
    val owner = newActor("fowner");
    val parent = newActor("fparent"); // stand-in for the parent .ton DnsItem

    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val expectedColl = factory.getCollectionAddress(parent.address);
    val payload = beginCell()
        .storeRef(makeMeta().toCell())
        .endCell()
        .beginParse();                                                              // 1 ref = the config

    val res = factory.sendOwnershipAssigned(
        parent.address,
        1,
        owner.address,
        payload,
        { value: ton("0.5"), bounce: false },
    );
    expect(res).toHaveSuccessfulTx({ to: factory.address });

    // the collection was deployed at the deterministic address, locked, admin = the previous owner
    val deployTx = res.findTransaction({ from: factory.address, deploy: true });
    expect(deployTx).toBeNotNull();
    expect(deployTx!.getAccountAddress()).toEqual(expectedColl);
    val coll = SubdomainCollection.fromAddress(expectedColl);
    expect(coll.isLocked()).toEqual(true);
    expect(coll.getAdmin()).toEqual(owner.address);

    // the `.ton` was handed off (factory -> parent DnsItem, a TransferOwnership)
    val handoffTx = res.findTransaction<TransferOwnership>({
        from: factory.address,
        to: parent.address,
    });
    expect(handoffTx).toBeNotNull();
    val transferBody = handoffTx!.loadInMsg<TransferOwnership>().body;
    val transfer = match (transferBody) {
        TlbEitherLeft => transferBody.value,
        TlbEitherRight => transferBody.value.load(),
    };
    var proofPayload = transfer.transferData.forwardPayload;
    expect(proofPayload.loadBool()).toEqual(true);
    val proof = FactoryHandoff.fromCell(proofPayload.loadRef());
    expect(proof.intendedAdmin).toEqual(owner.address);
    expect(transfer.transferData.responseDestination).toEqual(owner.address);
}

get fun `test factory: underfunded create returns the .ton, deploys nothing`() {
    val owner = newActor("fowner2");
    val parent = newActor("fparent2");

    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    val payload = beginCell().storeRef(makeMeta().toCell()).endCell().beginParse();
    val res = factory.sendOwnershipAssigned(
        parent.address,
        1,
        owner.address,
        payload,
        { value: ton("0.1"), bounce: false }, // < MIN_CREATE_VALUE
    );

    // the `.ton` is returned to the owner; nothing is deployed
    expect(
        res.findTransaction<TransferOwnership>({ from: factory.address, to: parent.address }),
    ).toBeNotNull();
    expect(res.findTransaction({ from: factory.address, deploy: true })).toEqual(null);
}

get fun `test factory: two parents get two distinct collections`() {
    val deployer = newActor("fdeployer2");
    val parentA = newActor("parentA");
    val parentB = newActor("parentB");

    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(deployer.address, { value: ton("1"), bounce: false });

    val addrA = factory.getCollectionAddress(parentA.address);
    val addrB = factory.getCollectionAddress(parentB.address);
    expect(addrA == addrB).toEqual(false);
}
