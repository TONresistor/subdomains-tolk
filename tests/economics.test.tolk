// Economics: right-sized item deposit + buyer refund of overpayment (see economics audit).
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "test-utils"
import "../contracts/errors"
import "../contracts/storage"
import "../wrappers/SubdomainCollection.gen"
import "../wrappers/SubdomainItem.gen"

// "alice" = 5 chars -> default price 5 TON. Required = price + deploy + buffer + per-name rent.
const ALICE_PRICE = ton("5")
const REQUIRED = ALICE_PRICE + ITEM_DEPLOY_COST + MINT_FEE_BUFFER + PER_NAME_RENT_RESERVE

get fun `test economics: a freshly-minted item holds the small deposit, not 1 TON`() {
    val (coll, parent, owner, user) = deployLockedCollection();
    val (item, _res) = mintSubdomain(coll, user, "alice"); // helper overpays (20 TON)

    // The item keeps ITEM_DEPLOY_COST (~0.07), NOT the old 1.1/1 TON of dead capital.
    val bal = testing.getAccountBalance(item.address);
    expect(bal > ton("0.04")).toEqual(true);
    expect(bal < ton("0.1")).toEqual(true);
}

get fun `test economics: overpayment is refunded to the buyer (only the price is kept)`() {
    val (coll, parent, owner, user) = deployLockedCollection();

    // Send 20 TON for a 5 TON name; the ~14.9 excess must come back to the buyer.
    val before = testing.getAccountBalance(user.address);
    val (item, res) = mintSubdomain(coll, user, "alice", ton("20"));
    expect(testing.isDeployed(item.address)).toEqual(true);

    // a refund message went back to the buyer...
    expect(res).toHaveSuccessfulTx({ from: coll.address, to: user.address });

    // ...crediting back EXACTLY the overpayment: 20 - price(5) - deploy(0.07) - buffer(0.03) = 14.9 TON.
    val refundReceived = testing.getAccountBalance(user.address) - before;
    expect(refundReceived > ton("14.85")).toEqual(true);
    expect(refundReceived < ton("14.95")).toEqual(true);
}

get fun `test economics: exact funding mints with no refund`() {
    val (coll, parent, owner, user) = deployLockedCollection();

    // Send exactly price + deploy + buffer; refund is 0 so no buyer-bound message.
    val (item, res) = mintSubdomain(coll, user, "alice", REQUIRED);
    expect(testing.isDeployed(item.address)).toEqual(true);
    expect(res.findTransaction({ from: coll.address, to: user.address })).toEqual(null);
}

get fun `test economics: under the price+deploy+buffer floor is rejected`() {
    val (coll, parent, owner, user) = deployLockedCollection();

    val res = coll.sendRegisterSubdomain(
        user.address,
        7,
        labelSlice("alice"),
        true,
        null,
        { value: REQUIRED - ton("0.01"), bounce: true }, // 5.09 < 5.1
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_MINT_VALUE });
}

get fun `test economics: admin withdraws real revenue (no longer stranded by a 1 TON floor)`() {
    val (coll, parent, owner, user) = deployLockedCollection();
    mintSubdomain(coll, user, "alice", ton("20")); // 5 TON price now sits on the collection

    // Old keep was 1.07 TON, so withdraw returned ~0 for cheap sales. Now the admin collects the revenue.
    val before = testing.getAccountBalance(owner.address);
    val res = coll.sendWithdrawFees(owner.address, 1, 0, { value: ton("1"), bounce: true });
    expect(res).toHaveSuccessfulTx({ from: coll.address, to: owner.address });
    val after = testing.getAccountBalance(owner.address);
    expect(after > before).toEqual(true);
}
