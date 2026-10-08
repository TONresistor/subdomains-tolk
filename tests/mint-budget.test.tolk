import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/tlb/maybe"
import "@acton/types/big_array"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/errors"
import "@contracts/messages"
import "@contracts/metadata"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "test-utils"

fun budgetLabel(length: int): slice {
    var b = beginCell().storeUint(97, 8);
    repeat (length - 2) {
        b.storeUint(45, 8);
    }
    return b.storeUint(97, 8).endCell().beginParse();
}

fun maxCellsContent(): cell {
    var tail = beginCell().storeUint(0, 256).storeUint(0, 256).endCell();
    var i = 1;
    repeat (29) {
        var node = beginCell().storeUint(i, 16).storeUint(0, 256);
        if (i == 29) {
            node.storeUint(0, 256).storeUint(0, 256).storeUint(0, 239);
        } else {
            node.storeUint(0, 240);
        }
        tail = node.storeRef(tail).endCell();
        i += 1;
    }
    var fields: map<uint256, cell> = [];
    fields.set("name".sha256(), tail);
    val content = beginCell().storeUint(0, 8).storeDict(fields.toLowLevelDict()).endCell();
    val (cells, bits, _, complete) = content.calculateSize(MAX_METADATA_CELLS);
    expect(complete).toEqual(true);
    expect(cells).toEqual(MAX_METADATA_CELLS);
    expect(bits! <= MAX_METADATA_BITS).toEqual(true);
    assertOnchainMetadata(content);
    return content;
}

fun seededBudgetCollection(count: int, linked: bool): (SubdomainCollection, Treasury, Treasury) {
    val master = newActor("budget-master");
    val parent = newActor("budget-parent");
    val admin = newActor("budget-admin");
    val user = newActor("budget-user");
    var minted: map<uint256, ()> = [];
    var i = 0;
    repeat (count) {
        val label = beginCell()
            .storeSlice(labelSlice("fill"))
            .storeUint(97 + i / 676, 8)
            .storeUint(97 + (i / 26) % 26, 8)
            .storeUint(97 + i % 26, 8)
            .endCell()
            .beginParse();
        minted.set(label.hash(), ());
        i += 1;
    }
    val state: CollectionStorage = {
        master: master.address,
        parentDomain: parent.address,
        admin: admin.address,
        origin: CollectionOrigin {
            linkedAdmin: linked ? admin.address : master.address,
            isLinkedAtDeployment: linked,
            lastFactoryHandoff: null,
        }.toCell(),
        isLinked: linked,
        lastParentFillUp: blockchain.now(),
        meta: makeMeta().toCell(),
        names: CollectionNames {
            reserved: [],
            minted,
            mintedCount: count,
        }.toCell(),
        policy: CollectionPolicyState {
            accessMode: ACCESS_PUBLIC,
            withdrawableRevenue: 0,
            allowlist: [],
            pendingMints: [],
            parentGeneration: 0,
            pendingParentReturn: null,
        }.toCell(),
    };
    val stateInit: ContractState = { code: build("SubdomainCollection"), data: state.toCell() };
    val coll = SubdomainCollection {
        address: AutoDeployAddress { stateInit }.calculateAddress(),
        stateInit,
    };
    coll.deploy(master.address, { value: grams("1"), bounce: false });
    expect(coll.getMintedCount()).toEqual(count);
    return (coll, parent, user);
}

fun collectionRent(result: SendResultList, collection: address): coins {
    var rent: coins = 0;
    var i = 0;
    repeat (result.size()) {
        val tx = result.at(i).tx.load();
        if (tx.getAccountAddress() == collection) {
            val description = tx.description.load();
            if (description is TlbTransOrd) {
                val storage = description.storagePh.unwrapOr(null);
                if (storage != null) {
                    rent += storage.storageFeesCollected;
                }
            }
        }
        i += 1;
    }
    return rent;
}

get fun `test mint budget: 64 and 65 boundaries agree with mint admission`() {
    testing.setNow(1700000000);
    val (coll, _parent, _admin, user) = deployLockedCollection();
    val q64 = coll.getMintQuote(user.address, 64);
    val q65 = coll.getMintQuote(user.address, 65);
    expect(q64.requiredValue - q64.effectivePrice).toEqual(grams("0.07"));
    expect(q65.requiredValue - q65.effectivePrice).toEqual(grams("0.072"));
    val legacy = coll.sendRegisterSubdomain(
        user.address,
        1,
        budgetLabel(65),
        true,
        testOnchainMetadata(),
        { value: q65.effectivePrice + grams("0.07"), bounce: true },
    );
    expect(legacy).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_MINT_VALUE });
    val short = coll.sendRegisterSubdomain(
        user.address,
        2,
        budgetLabel(65),
        true,
        testOnchainMetadata(),
        { value: q65.requiredValue - 1, bounce: true },
    );
    expect(short).toHaveFailedTx({ to: coll.address, exitCode: ERROR_INSUFFICIENT_MINT_VALUE });
    expect(coll.getMintedCount()).toEqual(0);
    expect(coll.getIsMintPending(budgetLabel(65).hash())).toEqual(false);
    val a = coll.sendRegisterSubdomain(
        user.address,
        3,
        budgetLabel(64),
        true,
        testOnchainMetadata(),
        { value: q64.requiredValue, bounce: true },
    );
    expect(a).toHaveSuccessfulTx({ to: coll.address });
    val b = coll.sendRegisterSubdomain(
        user.address,
        4,
        budgetLabel(65),
        true,
        testOnchainMetadata(),
        { value: q65.requiredValue, bounce: true },
    );
    expect(b).toHaveSuccessfulTx({ to: coll.address });
    expect(a.findTransaction<Excesses>({ from: coll.address, to: user.address })).toEqual(null);
    expect(b.findTransaction<Excesses>({ from: coll.address, to: user.address })).toEqual(null);
    expect(coll.getWithdrawableRevenue()).toEqual(q64.effectivePrice + q65.effectivePrice);
}

fun stressBudget(count: int, linked: bool, due: bool) {
    testing.setNow(1700000000);
    val (coll, parent, user) = seededBudgetCollection(count, linked);
    if (due) {
        testing.setNow(1700000000 + PARENT_HEARTBEAT_INTERVAL + 1);
    }
    val content = maxCellsContent();
    val lengths: array<int> = due ? [126, 64, 65] : [64, 65, 126];
    var i = 0;
    repeat (3) {
        val length = lengths.get(i);
        val quote = coll.getMintQuote(user.address, length);
        val base = length == 64 ? grams("0.07") : grams("0.072");
        val heartbeat = !linked && due && i == 0;
        expect(quote.requiredValue - quote.effectivePrice).toEqual(
            base + (heartbeat ? PARENT_HEARTBEAT_AMOUNT : 0 as coins),
        );
        val before = testing.getAccountBalance(coll.address);
        val surplus = due ? grams("0.05") : 0 as coins;
        val res = coll.sendRegisterSubdomain(
            user.address,
            i + 10,
            budgetLabel(length),
            true,
            content,
            { value: quote.requiredValue + surplus, bounce: true },
        );
        expect(res).toHaveSuccessfulTx({ to: coll.address });
        expect(coll.getIsMintPending(budgetLabel(length).hash())).toEqual(false);
        expect(coll.getMintedCount()).toEqual(count + i + 1);
        expect(
            testing.getAccountBalance(coll.address) + collectionRent(res, coll.address),
        ).toBeGreaterOrEqual(before + quote.effectivePrice);
        expect(res.findTransaction({ from: coll.address, to: parent.address }) != null).toEqual(
            heartbeat,
        );
        val refund = res.findTransaction<Excesses>({ from: coll.address, to: user.address });
        if (surplus > 0) {
            expect(refund).toBeNotNull();
            expect(internalBudgetValue(refund!)).toEqual(surplus);
        } else {
            expect(refund).toEqual(null);
        }
        i += 1;
    }
}

fun internalBudgetValue(tx: TlbTransaction): coins {
    val info = tx.loadInMsg<Excesses>().info;
    if (info is TlbInternalMessage) {
        return info.value.grams;
    }
    throw 0;
}

get fun `test mint budget: 75 names and 32 metadata cells`() {
    stressBudget(75, false, false);
}

get fun `test mint budget: 1000 names due renewal and overpayment`() {
    stressBudget(1000, false, true);
}

get fun `test mint budget: Linked registry never adds parent renewal`() {
    stressBudget(1000, true, true);
}
