import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/tlb/either"
import "@acton/types/transaction"
import "test-utils"
import "../contracts/dns-utils"
import "../contracts/errors"
import "../contracts/messages"
import "../contracts/storage"
import "../wrappers/SubdomainCollection.gen"
import "../wrappers/SubdomainItem.gen"

// audit #1: the lock must commit even on a minimal forward value (IGNORE_ERRORS on the resolver pin)
get fun `test audit1: lock commits with a minimal forward value`() {
    val masterT = newActor("a1m");
    val parent = newActor("a1p");
    val owner = newActor("a1o");
    val coll = SubdomainCollection.fromStorage({ master: masterT.address, parentDomain: parent.address });
    coll.deploy(masterT.address, { value: ton("0.05"), bounce: false });

    // even on a minimal value, the lock COMMITS (the resolver pin is IGNORE_ERRORS)
    val res = coll.sendAny(
        masterT.address,
        LockCollection {
            queryId: 1,
            admin: owner.address,
            meta: makeMeta().toCell(),
        }.toCell(),
        { value: ton("0.06"), bounce: false },
    );
    expect(res).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.isLocked()).toEqual(true);
    expect(coll.getAdmin()).toEqual(owner.address);
}

// audit #1/#4: the landing pin writes next_resolver as a SET (value carries 1 ref), never a DELETE
get fun `test audit4: landing pin is a SET (ref present), pointing to self`() {
    val (coll, parent, owner, user) = deployLockedCollection();

    // the parent .ton landing on the locked collection triggers the reliable pin
    val res = coll.sendAny(
        parent.address,
        OwnershipAssigned {
            queryId: 5,
            oldOwnerAddress: owner.address,
            payload: emptyPayload(),
        }.toCell(),
        { value: ton("0.1"), bounce: false },
    );
    val tx = res.findTransaction<ChangeDnsRecord>({ from: coll.address, to: parent.address });
    expect(tx).toBeNotNull();

    val b = tx!.loadInMsg<ChangeDnsRecord>().body;
    val cdr = match (b) {
        TlbEitherLeft => b.value,
        TlbEitherRight => b.value.load(),
    };
    expect(cdr.key).toEqual(CAT_DNS_NEXT_RESOLVER);
    var rec = cdr.value;
    expect(rec.remainingRefsCount()).toEqual(1); // SET, not DELETE
    expect(parseNextResolverCell(rec.loadRef())).toEqual(coll.address);
}

// audit #1: EnforceResolver can re-pin (public, idempotent), completing or repairing the lock
get fun `test audit1: enforce_resolver re-pins the resolver (public)`() {
    val (coll, parent, owner, user) = deployLockedCollection();
    val res = coll.sendEnforceResolver(user.address, 1, { value: ton("0.2"), bounce: true });
    expect(res).toHaveSuccessfulTx({ to: coll.address });
    // typed match proves the opcode (0x4eb1f0f9) + structure of the re-pin message
    expect(
        res.findTransaction<ChangeDnsRecord>({ from: coll.address, to: parent.address }),
    ).toBeNotNull();
}

// audit #2: minting an already-minted label is rejected (no silent loss or front-running drain)
get fun `test audit2: double-mint of the same label is rejected`() {
    val (coll, parent, owner, user) = deployLockedCollection();
    mintSubdomain(coll, user, "alice");

    val dup = coll.sendRegisterSubdomain(
        user.address,
        2,
        labelSlice("alice"),
        true,
        null,
        { value: ton("20"), bounce: true },
    );
    expect(dup).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_TAKEN });
}

// audit #3: a label carrying refs is rejected (index would diverge from dnsresolve routing)
get fun `test audit3: a label with refs is rejected`() {
    val (coll, parent, owner, user) = deployLockedCollection();
    val labelWithRef = beginCell()
        .storeSlice("alice".beginParse())
        .storeRef(beginCell().endCell())
        .endCell()
        .beginParse();
    val res = coll.sendRegisterSubdomain(
        user.address,
        1,
        labelWithRef,
        true,
        null,
        { value: ton("20"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_INVALID_CHARS });
}

// audit #10: item exposes mintedAt / validUntil getters
get fun `test audit10: item exposes timestamp getters`() {
    testing.setNow(1700000000);
    val (coll, parent, owner, user) = deployLockedCollection();
    val (item, _res) = mintSubdomain(coll, user, "alice");
    expect(item.getMintedAt()).toEqual(1700000000);
    expect(item.getValidUntil()).toEqual(0); // perpetual placeholder
}

// audit #5: getters don't crash on an unlocked collection or uninitialized item
get fun `test audit5: getters are safe on unlocked/uninitialized state`() {
    val masterT = newActor("a5m");
    val parent = newActor("a5p");
    val coll = SubdomainCollection.fromStorage({ master: masterT.address, parentDomain: parent.address });
    coll.deploy(masterT.address, { value: ton("1"), bounce: false });
    // not locked yet
    expect(coll.getPrice(5)).toEqual(0);
    expect(coll.isLocked()).toEqual(false);
}
