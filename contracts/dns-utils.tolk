// DNS helpers (TEP-81). Trimmed and adapted from the official acton-contracts/dns/dns-utils.tolk.
import "errors"

const BYTE_SIZE = 8

// https://github.com/ton-blockchain/ton/blob/master/crypto/block/block.tlb (dns_next_resolver#ba93)
const DNS_NEXT_RESOLVER_PREFIX = 0xba93

const MAX_DOMAIN_SIZE = 126 // minimum is per-registry (PriceConfig.minChars)

// TEP-81 dictionary keys are sha256(category-name), not raw category bytes.
const CAT_DNS_NEXT_RESOLVER = "dns_next_resolver".sha256()
const CAT_WALLET = "wallet".sha256()
const CAT_SITE = "site".sha256()
// Category name and TL-B value type are distinct: clients use sha256("storage") as the dictionary
// key, while dns_storage_address#7473 is the record VALUE tag.
const CAT_STORAGE = "storage".sha256()

fun address.forceBasechain(self) {
    assert (self.getWorkchain() == BASECHAIN) throw ERROR_WRONG_WORKCHAIN;
}

// dns_next_resolver#ba93 resolver:MsgAddressInt = DNSRecord
fun address.toNextResolver(self): cell {
    return beginCell().storeUint(DNS_NEXT_RESOLVER_PREFIX, 16).storeAddress(self).endCell();
}

// dns_smc_address#9fd3 smc_addr:MsgAddressInt flags:(## 8) ... = DNSRecord  (wallet record)
fun buildWalletRecord(wallet: address): cell {
    return beginCell().storeUint(0x9fd3, 16).storeAddress(wallet).storeUint(0, 8).endCell();
}

// Shared TEP-81 query-shape validation for collection and item resolvers.
fun dnsQueryStartsWithZero(subdomain: slice): bool {
    val bits = subdomain.remainingBitsCount();
    assert (bits >= BYTE_SIZE && bits % BYTE_SIZE == 0) throw ERROR_DNS_INVALID_SUBDOMAIN_BITS;
    return subdomain.preloadInt(BYTE_SIZE) == 0;
}

fun assertDnsQueryStartsWithZero(subdomain: slice) {
    assert (dnsQueryStartsWithZero(subdomain)) throw ERROR_DNS_INVALID_SUBDOMAIN_BITS;
}

fun getTopDomainBits(domain: slice): int {
    var bytes = domain;
    var bits = 0;
    var shouldStop = false;

    while (!shouldStop) {
        assert (bytes.remainingBitsCount() >= BYTE_SIZE) throw ERROR_DNS_INVALID_SUBDOMAIN_BITS;
        val ch = bytes.loadUint(BYTE_SIZE);
        shouldStop = ch == 0;
        if (!shouldStop) {
            bits += BYTE_SIZE;
        }
    }

    assert (bits > 0) throw ERROR_LABEL_TOO_SHORT;
    return bits;
}

enum DomainChar {
    Hyphen = 45
    DigitZero = 48
    DigitNine = 57
    LowercaseA = 97
    LowercaseZ = 122
}

// a-z / 0-9 / '-' (hyphen only in interior position, never first/last). `len` in bits.
@inline_ref
fun checkDomainString(domain: slice, len: int): bool {
    var bytes = domain;
    var i = 0;

    val charCount = len / BYTE_SIZE;
    val lastChar = charCount - 1;

    repeat (charCount) {
        val ch = bytes.loadUint(BYTE_SIZE);

        val isDigit = ch >= (DomainChar.DigitZero as int) && ch <= (DomainChar.DigitNine as int);
        val isLowercaseLetter = ch >= (DomainChar.LowercaseA as int) &&
        ch <= (DomainChar.LowercaseZ as int);

        var valid = isDigit || isLowercaseLetter;
        if (!valid) {
            valid = ch == (DomainChar.Hyphen as int) && i > 0 && i < lastChar;
        }
        if (!valid) {
            return false;
        }
        i += 1;
    }

    return true;
}
