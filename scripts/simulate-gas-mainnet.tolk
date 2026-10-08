import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/big_array"
import "@acton/types/transaction"
import "@contracts/dns-utils"
import "@contracts/errors"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "@wrappers/SubdomainItem.gen"

fun metrics(name: string, result: SendResultList, before: coins, coll: address) {
    var gas = 0;
    var fees = 0;
    var i = 0;
    repeat (result.size()) {
        val tx = result.at(i);
        gas += tx.gasUsed;
        fees += tx.tx.load().totalFees.grams;
        i += 1;
    }
    println(
        "METRIC {} tx={} gas={} collectedFeesNano={} collectionDeltaNano={}",
        name,
        result.size(),
        gas,
        fees,
        testing.getAccountBalance(coll) - before,
    );
    println(result);
}

fun content(large: bool): cell {
    if (!large) {
        return beginCell().storeUint(0, 8).storeBool(false).endCell();
    }
    var tail = beginCell()
        .storeUint(0, 250)
        .storeUint(0, 250)
        .storeUint(0, 250)
        .storeUint(0, 250)
        .endCell();
    repeat (13) {
        tail = beginCell()
            .storeUint(0, 250)
            .storeUint(0, 250)
            .storeUint(0, 250)
            .storeUint(0, 250)
            .storeRef(tail)
            .endCell();
    }
    var fields: map<uint256, cell> = [];
    fields.set(
        "name".sha256(),
        beginCell()
            .storeUint(0, 8)
            .storeUint(0, 248)
            .storeUint(0, 248)
            .storeUint(0, 248)
            .storeUint(0, 248)
            .storeRef(tail)
            .endCell(),
    );
    return beginCell().storeUint(0, 8).storeDict(fields.toLowLevelDict()).endCell();
}

fun mint(
    coll: SubdomainCollection,
    user: address,
    label: slice,
    name: string,
    large: bool = false,
    extra: coins = 0,
): SubdomainItem {
    val quote = coll.getMintQuote(user, label.remainingBitsCount() / 8);
    expect(quote.allowed).toEqual(true);
    expect(quote.effectivePrice).toEqual(0);
    val count = coll.getMintedCount();
    val before = testing.getAccountBalance(coll.address);
    val result = coll.sendRegisterSubdomain(
        user,
        count + 1000,
        label,
        true,
        content(large),
        { value: quote.requiredValue + extra, bounce: true },
    );
    expect(result).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getMintedCount()).toEqual(count + 1);
    expect(coll.getIsMintPending(label.hash())).toEqual(false);
    expect(coll.getWithdrawableRevenue()).toEqual(0);
    val item = SubdomainItem.fromAddress(coll.getNftAddressByIndex(label.hash()));
    expect(testing.isDeployed(item.address)).toEqual(true);
    expect(item.getNftData().ownerAddress).toEqual(user);
    metrics(name, result, before, coll.address);
    println("ITEM {} balanceNano={}", name, testing.getAccountBalance(item.address));
    return item;
}

fun repeatedLabel(ch: int, length: int): slice {
    var b = beginCell();
    repeat (length) {
        b.storeUint(ch, 8);
    }
    return b.endCell().beginParse();
}

fun main(worstOnly: bool = false) {
    assert (!net.isBroadcasting()) throw 9000;
    val coll = SubdomainCollection.fromAddress(
        address("EQC7wJbyOU3Mpdcb3al81CgybxKQMlch2KTS1QtYS1i4AaIX"),
    );
    val state = testing.getAccountState(coll.address)!;
    testing.setNow(state.storageStat.lastPaid + 1);
    val user = testing.treasury("mainnet-gas-minter");
    val recipient = testing.treasury("mainnet-gas-recipient");
    val admin = coll.getAdmin()!;
    val initial = testing.getAccountBalance(coll.address);
    println(
        "START balanceNano={} minted={} revenue={} admin={}",
        initial,
        coll.getMintedCount(),
        coll.getWithdrawableRevenue(),
        admin,
    );
    if (worstOnly) {
        var worst = beginCell().storeUint(120, 8);
        repeat (124) {
            worst.storeUint(45, 8);
        }
        worst.storeUint(120, 8);
        mint(coll, user.address, worst.endCell().beginParse(), "126-hyphens-large-metadata", true);
        return;
    }
    mint(coll, user.address, "gasforkone".beginParse(), "normal");
    mint(
        coll,
        user.address,
        "gasforktwo".beginParse(),
        "overpayment",
        false,
        grams("1"),
    );
    mint(coll, user.address, repeatedLabel(113, 126), "126-letters");
    mint(coll, user.address, repeatedLabel(55, 126), "126-digits");
    var mixed = beginCell().storeUint(122, 8);
    repeat (124) {
        mixed.storeUint(45, 8);
    }
    mixed.storeUint(122, 8);
    mint(coll, user.address, mixed.endCell().beginParse(), "126-hyphens");
    mint(coll, user.address, repeatedLabel(118, 126), "126-large-metadata", true);
    val item = mint(coll, user.address, "gasforkitem".beginParse(), "item-lifecycle");
    var before = testing.getAccountBalance(coll.address);
    val edit = item.sendChangeDnsRecord(
        user.address,
        1,
        CAT_WALLET,
        beginCell().storeRef(buildWalletRecord(recipient.address)).endCell().beginParse(),
        { value: grams("0.01"), bounce: true },
    );
    expect(edit).toHaveSuccessfulTx({ to: item.address });
    metrics("edit-dns", edit, before, coll.address);
    val transfer = item.sendTransferOwnership(
        user.address,
        2,
        {
            newOwnerAddress: recipient.address,
            responseDestination: user.address,
            customPayload: null,
            forwardAmount: 0,
            forwardPayload: beginCell().storeBool(false).endCell().beginParse(),
        },
        { value: grams("0.01"), bounce: true },
    );
    expect(transfer).toHaveSuccessfulTx({ to: item.address });
    expect(item.getNftData().ownerAddress).toEqual(recipient.address);
    metrics("transfer-item", transfer, before, coll.address);
    before = testing.getAccountBalance(coll.address);
    val underQuote = coll.getMintQuote(user.address, 12);
    val under = coll.sendRegisterSubdomain(
        user.address,
        3,
        "gasforkunder".beginParse(),
        true,
        content(false),
        { value: underQuote.requiredValue - 1, bounce: true },
    );
    expect(under).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_MINT_VALUE });
    metrics("underfunded", under, before, coll.address);
    before = testing.getAccountBalance(coll.address);
    val duplicate = coll.sendRegisterSubdomain(
        user.address,
        4,
        "gasforkone".beginParse(),
        true,
        content(false),
        { value: grams("0.1"), bounce: true },
    );
    expect(duplicate).toHaveFailedTx({ to: coll.address, exitCode: ERROR_LABEL_TAKEN });
    metrics("duplicate", duplicate, before, coll.address);
    before = testing.getAccountBalance(coll.address);
    val withdraw = coll.sendWithdrawFees(admin, 5, 0, { value: grams("0.01"), bounce: true });
    expect(withdraw).toHaveSuccessfulTx({ to: coll.address });
    expect(coll.getWithdrawableRevenue()).toEqual(0);
    metrics("withdraw-zero-revenue", withdraw, before, coll.address);
    testing.setNow(state.storageStat.lastPaid + PARENT_HEARTBEAT_INTERVAL + 2);
    mint(coll, user.address, "gasforkrenew".beginParse(), "heartbeat-due");
    var seq = 0;
    repeat (32) {
        val label = beginCell()
            .storeSlice("gasforkgrowth".beginParse())
            .storeUint(97 + seq / 26, 8)
            .storeUint(97 + seq % 26, 8)
            .endCell()
            .beginParse();
        mint(coll, user.address, label, "dictionary-growth");
        seq += 1;
    }
    println(
        "END balanceNano={} netDeltaNano={} minted={} revenue={}",
        testing.getAccountBalance(coll.address),
        testing.getAccountBalance(coll.address) - initial,
        coll.getMintedCount(),
        coll.getWithdrawableRevenue(),
    );
}
