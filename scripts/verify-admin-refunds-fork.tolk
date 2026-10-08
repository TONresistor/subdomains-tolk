import "@acton/build"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/messages"
import "@wrappers/SubdomainCollection.gen"

fun installCandidate(addr: address, original: TlbShardAccount) {
    var shard = original;
    var account = shard.account.load();
    if (account is TlbAccountInfo) {
        var state = account.storage.state;
        if (state is TlbAccountStateActive) {
            state.stateInit.code = build("SubdomainCollection");
            account.storage.state = state;
            shard.account = account.toCell() as cell as Cell<TlbAccount>;
            testing.setShardAccount(addr, shard);
            val check = testing.getAccountState(addr)!.storage.state;
            if (check is TlbAccountStateActive) {
                println("candidate code: {:x}", check.stateInit.code!.hash());
                expect(check.stateInit.code!.hash()).toEqual(build("SubdomainCollection").hash());
            }
            return;
        }
    }
    throw 1000;
}

fun checkRefund(
    name: string,
    result: SendResultList,
    addr: address,
    admin: address,
    balance: coins,
    queryId: uint64,
) {
    expect(result).toHaveSuccessfulTx({ to: addr });
    val reply = result.findTransaction<Excesses>({ from: addr, to: admin });
    if (reply == null) {
        println(result);
    }
    expect(reply).toBeNotNull();
    expect(reply!.loadBody<Excesses>().queryId).toEqual(queryId);
    expect(testing.getAccountBalance(addr)).toEqual(balance);
    val info = reply!.loadInMsg<Excesses>().info;
    if (info is TlbInternalMessage) {
        expect(info.value.grams > grams("0.045")).toEqual(true);
        expect(info.value.grams < grams("0.05")).toEqual(true);
        println(
            "{}: refunded={} nanograms, collection balance preserved={}",
            name,
            info.value.grams,
            balance,
        );
        return;
    }
    throw 1001;
}

fun verify(name: string, addr: address) {
    var original = testing.getShardAccount(addr)!;
    var account = original.account.load();
    if (account is TlbAccountInfo) {
        testing.setNow(max(testing.getNow(), account.storageStat.lastPaid));
        account.storageStat.lastPaid = testing.getNow();
        original.account = account.toCell() as cell as Cell<TlbAccount>;
        testing.setShardAccount(addr, original);
    }
    val coll = SubdomainCollection.fromAddress(addr);
    val admin = coll.getAdmin()!;
    val balance = testing.getAccountBalance(addr);
    val revenue = coll.getWithdrawableRevenue();
    val access = coll.getAccessMode();
    val legacy = coll.sendSetAccessMode(admin, 900, access, { value: grams("0.05"), bounce: true });
    expect(legacy).toHaveSuccessfulTx({ to: addr });
    expect(legacy.findTransaction<Excesses>({ from: addr, to: admin })).toEqual(null);
    println("{} deployed: retained={} nanograms", name, testing.getAccountBalance(addr) - balance);

    installCandidate(addr, original);
    val settings = coll.sendSetAccessMode(
        admin,
        901,
        access,
        { value: grams("0.05"), bounce: true },
    );
    checkRefund(
        name,
        settings,
        addr,
        admin,
        balance,
        901,
    );
    val allow = coll.sendSetAllowlistEntry(
        admin,
        902,
        admin,
        true,
        { value: grams("0.05"), bounce: true },
    );
    checkRefund(
        "allowlist",
        allow,
        addr,
        admin,
        balance,
        902,
    );
    val reserved = coll.sendSetLabelReserved(
        admin,
        903,
        "admin-refund-check".beginParse().hash(),
        true,
        { value: grams("0.05"), bounce: true },
    );
    checkRefund(
        "reservation",
        reserved,
        addr,
        admin,
        balance,
        903,
    );
    if (!coll.getIsLinked() && revenue == 0) {
        val withdrawal = coll.sendWithdrawFees(
            admin,
            904,
            0,
            { value: grams("0.05"), bounce: true },
        );
        checkRefund(
            "zero-revenue withdrawal",
            withdrawal,
            addr,
            admin,
            balance,
            904,
        );
    }
    expect(coll.getWithdrawableRevenue()).toEqual(revenue);
}

fun main() {
    assert (!net.isBroadcasting()) throw 1002;
    verify("syndi.ton", address("EQAVH_SyDKKGfwtdfZQA__QdVGiLKh75EC9JegUYQg7Fdfdl"));
    verify("ton-site.ton", address("EQC7wJbyOU3Mpdcb3al81CgybxKQMlch2KTS1QtYS1i4AaIX"));
}
