import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "test-utils"
import "../contracts/storage"
import "../wrappers/SubdomainCollection.gen"

get fun `test renew: explicit fill_up_parent renews the parent lease (throttled)`() {
    testing.setNow(1700000000);
    val (coll, parent, owner, user) = deployLockedCollection();
    expect(coll.getLastParentFillUp()).toEqual(1700000000); // set at lock time

    // within the throttle window an immediate fill-up is a no-op (anti public-drain)
    val early = coll.sendFillUpParent(owner.address, 1, { value: ton("1"), bounce: true });
    expect(early.findTransaction({ from: coll.address, to: parent.address })).toEqual(null);
    expect(coll.getLastParentFillUp()).toEqual(1700000000);

    // past the window it renews: a heartbeat (empty-body op 0) is sent and the timer advances
    testing.setNow(1700000000 + 86400 + 10);
    val res = coll.sendFillUpParent(owner.address, 1, { value: ton("1"), bounce: true });
    expect(res).toHaveSuccessfulTx({ to: coll.address });
    expect(res.findTransaction({ from: coll.address, to: parent.address })).toBeNotNull();
    expect(coll.getLastParentFillUp()).toEqual(1700000000 + 86400 + 10);
}

get fun `test renew: minting renews the parent (throttled to once per day)`() {
    testing.setNow(1700000000);
    val (coll, parent, owner, user) = deployLockedCollection();

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
    val (coll, parent, owner, user) = deployLockedCollection();
    val holder = newActor("holder");

    testing.setNow(1700000000 + 86400 + 10);
    val res = coll.sendFillUpParent(holder.address, 1, { value: ton("1"), bounce: true });
    expect(res).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getLastParentFillUp()).toEqual(1700000000 + 86400 + 10);
}
