import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "test-utils"
import "../contracts/errors"
import "../contracts/messages"
import "../contracts/storage"
import "../wrappers/SubdomainCollection.gen"

get fun `test register: insufficient value is rejected`() {
    val (coll, parent, owner, user) = deployLockedCollection();
    // price("alice"=5) = 5 TON, + ITEM_DEPLOY_COST 0.07 + MINT_FEE_BUFFER 0.03 = 5.1 required ; send 2
    val res = coll.sendRegisterSubdomain(
        user.address,
        1,
        labelSlice("alice"),
        true,
        null,
        { value: ton("2"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_MINT_VALUE });
}

get fun `test register: too-short label is rejected`() {
    val (coll, parent, owner, user) = deployLockedCollection();
    val res = coll.sendRegisterSubdomain(
        user.address,
        1,
        labelSlice("bob"),
        true,
        null, // 3 chars < 4
        { value: ton("50"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_TOO_SHORT });
}

get fun `test register: invalid characters are rejected`() {
    val (coll, parent, owner, user) = deployLockedCollection();
    val res = coll.sendRegisterSubdomain(
        user.address,
        1,
        labelSlice("hello!"),
        true,
        null, // '!' invalid
        { value: ton("50"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_INVALID_CHARS });
}

get fun `test register: reserved label blocks non-admin but allows admin`() {
    val (coll, parent, owner, user) = deployLockedCollection();
    val idx = labelIndex("vip");
    // admin reserves "vip"
    val reserveRes = coll.sendSetLabelReserved(
        owner.address,
        1,
        idx,
        true,
        { value: ton("1"), bounce: true },
    );
    expect(reserveRes).toHaveSuccessfulTx({ to: coll.address });

    // note: "vip" is 3 chars (too short); use a 5-char reserved label instead
    val idx2 = labelIndex("admin");
    coll.sendSetLabelReserved(owner.address, 2, idx2, true, { value: ton("1"), bounce: true });

    val userTry = coll.sendRegisterSubdomain(
        user.address,
        1,
        labelSlice("admin"),
        true,
        null,
        { value: ton("50"), bounce: true },
    );
    expect(userTry).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_RESERVED });

    val adminTry = coll.sendRegisterSubdomain(
        owner.address,
        2,
        labelSlice("admin"),
        true,
        null,
        { value: ton("50"), bounce: true },
    );
    expect(adminTry).toHaveSuccessfulTx({ to: coll.address });
}

get fun `test admin: transfer admin role, old admin loses rights`() {
    val (coll, parent, owner, user) = deployLockedCollection();
    val newAdmin = newActor("newadmin");

    val res = coll.sendTransferAdmin(
        owner.address,
        1,
        newAdmin.address,
        { value: ton("1"), bounce: true },
    );
    expect(res).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getAdmin()).toEqual(newAdmin.address);

    // old admin can no longer reserve labels
    val rogue = coll.sendSetLabelReserved(
        owner.address,
        2,
        labelIndex("zzzzz"),
        true,
        { value: ton("1"), bounce: true },
    );
    expect(rogue).toHaveFailedTx({ to: coll.address, exitCode: ERROR_NOT_ADMIN });
}

get fun `test rescue: admin cannot rescue the parent domain`() {
    val (coll, parent, owner, user) = deployLockedCollection();
    val res = coll.sendRescueNft(
        owner.address,
        1,
        parent.address,
        owner.address,
        { value: ton("1"), bounce: true },
    );
    expect(res).toHaveFailedTx({ to: coll.address, exitCode: ERROR_RESCUE_PARENT_FORBIDDEN });
}
