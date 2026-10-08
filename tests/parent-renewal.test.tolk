import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/errors"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "test-utils"

get fun `test renew: explicit fill_up_parent renews the parent lease (caller-funded)`() {
    testing.setNow(1700000000);
    val (coll, parent, owner, _user) = deployLockedCollection();
    expect(coll.getLastParentFillUp()).toEqual(1700000000); // set at lock time

    // a below-minimum fill reverts: the renew must be funded by the caller
    val tooLow = coll.sendFillUpParent(
        owner.address,
        1,
        { value: MIN_PARENT_FILL - 1, bounce: true },
    );
    expect(tooLow).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_BALANCE });

    // a funded fill renews anytime (no throttle): an empty-body op-0 heartbeat reaches the parent
    testing.setNow(1700000000 + 100);
    val res = coll.sendFillUpParent(
        owner.address,
        2,
        { value: MIN_PARENT_FILL, bounce: true },
    );
    expect(res).toHaveSuccessfulTx({ to: coll.address });
    expect(res.findTransaction({ from: coll.address, to: parent.address })).toBeNotNull();
    expect(coll.getLastParentFillUp()).toEqual(1700000000 + 100);
}

get fun `test renew: minting renews the parent (throttled to once per day)`() {
    testing.setNow(1700000000);
    val (coll, parent, _owner, user) = deployLockedCollection();

    // first mint at lock time: within the throttle window -> no extra heartbeat yet
    val (_item, res1) = mintSubdomain(coll, user, "alice");
    expect(coll.getLastParentFillUp()).toEqual(1700000000);
    expect(res1.findTransaction({ from: coll.address, to: parent.address })).toEqual(null);

    // after the throttle window, a mint heartbeats the parent automatically
    testing.setNow(1700000000 + 86400 + 10);
    val (_item2, res2) = mintSubdomain(coll, user, "bobby");
    expect(res2.findTransaction({ from: coll.address, to: parent.address })).toBeNotNull();
    expect(coll.getLastParentFillUp()).toEqual(1700000000 + 86400 + 10);
}

get fun `test renew: anyone (e.g. a subdomain holder) can renew the parent`() {
    testing.setNow(1700000000);
    val (coll, _parent, _owner, _user) = deployLockedCollection();
    val holder = newActor("holder");

    testing.setNow(1700000000 + 86400 + 10);
    val res = coll.sendFillUpParent(holder.address, 1, { value: ton("1"), bounce: true });
    expect(res).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getLastParentFillUp()).toEqual(1700000000 + 86400 + 10);
}
