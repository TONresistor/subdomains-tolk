// RED->GREEN against the REAL mainnet .ton DnsItem, offline, zero TON.
// Run: TONCENTER_MAINNET_API_KEY=... acton script scripts/verify-fork.tolk --fork-net mainnet
//
// Loads the real telegram-i00040.ton parent item (FunC nft-item.fc, real state) via fork,
// then applies OUR v7 pin (key = CAT_DNS_NEXT_RESOLVER = sha256) impersonating its owner,
// and shows the real contract's resolution flip from broken (null) to working (delegates).
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@contracts/dns-utils"

struct DnsReply {
    prefixBits: int
    record: cell?
}

const RAW_NEXT_RESOLVER = "dns_next_resolver".toBase256() // the buggy v6 key, for contrast

fun dotSlice(): slice {
    return beginCell().storeUint(0, 8).endCell().beginParse();
}

// internal name "\0test" — TEP-81 requires the leading \0 separator, then the label ("test")
fun subTest(): slice {
    return beginCell().storeUint(0, 8).storeUint(0x74657374, 32).endCell().beginParse();
}

fun resolveCat(item: address, sub: slice, cat: int): cell? {
    return net.runGetMethod<DnsReply>(item, "dnsresolve", [sub, cat]).record;
}

fun main() {
    val parent = address("EQBV7GD_sEy3EQeFEjxeEzDbidjHIHaM0RMtMmlkJmXHRPvY"); // real telegram-i00040.ton
    val owner = address("EQCPHzHuzLsch0Xj3PuhDgPuGwfMpeEaELox2QJQvpEFjPf1");  // its owner = our v6 collection

    println("== REAL mainnet telegram-i00040.ton (forked state) ==");
    println(
        "next_resolver under sha256 (standard) : {}",
        resolveCat(parent, dotSlice(), CAT_DNS_NEXT_RESOLVER) != null ? "FOUND" : "null  <- RED",
    );
    println(
        "next_resolver under raw bytes (v6 bug) : {}",
        resolveCat(parent, dotSlice(), RAW_NEXT_RESOLVER) != null
            ? "FOUND <- where the broken pin sits"
            : "null",
    );

    // --- apply OUR v7 pin: change_dns_record(sha256 key, next_resolver -> collection), from the owner ---
    val body = beginCell()
        .storeUint(0x4eb1f0f9, 32) // op::change_dns_record (real .ton item)
        .storeUint(1, 64) // query_id
        .storeUint(CAT_DNS_NEXT_RESOLVER, 256) // <- OUR v7 key (sha256), the only thing we fixed
        .storeRef(owner.toNextResolver()) // value: dns_next_resolver -> collection
        .endCell();

    val resolverPinMessage = createMessage({
        bounce: false,
        value: ton("0.1"),
        dest: parent,
        body,
    });
    testing.processSingleTraceStep(owner, resolverPinMessage);

    println("\n== after applying our v7 sha256 pin ==");
    println(
        "next_resolver under sha256 (standard) : {}",
        resolveCat(parent, dotSlice(), CAT_DNS_NEXT_RESOLVER) != null ? "FOUND <- GREEN" : "null",
    );

    // the real-world resolution path: a deeper subdomain now delegates instead of dead-ending
    val deeper = net.runGetMethod<DnsReply>(parent, "dnsresolve", [subTest(), 0]);
    println(
        "dnsresolve('test.<parent>') delegates : {}",
        deeper.record != null ? "next_resolver returned <- GREEN" : "null",
    );
}
