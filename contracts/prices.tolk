// Pricing by label character count. Chosen at creation, immutable thereafter.
// One price per length: p1 (1-char) .. p10 (10-char), then pRest (11+). Short names are the most
// premium, so the grid is non-increasing. minChars gates the shortest mintable length.
// 11 coins fit one cell for any realistic price (even 10M TON/name is ~712 bits < 1023); the
// theoretical worst case (varuint16 max) is unreachable, so suppress the static overflow check.
@overflow1023_policy("suppress")
struct PriceConfig {
    minChars: uint8 // shortest allowed subdomain (1..4), chosen at creation, frozen
    p1: coins
    p2: coins
    p3: coins
    p4: coins
    p5: coins
    p6: coins
    p7: coins
    p8: coins
    p9: coins
    p10: coins
    pRest: coins    // 11+ chars
}

const MIN_NAME_PRICE = ton("0.05") // floor on the cheapest tier; rejects degenerate/zero grids at create
const MAX_MIN_CHARS = 4 // a registry may set its minimum to 1, 2, 3 or 4

// A grid is valid iff minChars is in range, prices are non-increasing by length, and the cheapest
// tier is above the floor.
fun PriceConfig.isValid(self): bool {
    return self.minChars >= 1 && self.minChars <= MAX_MIN_CHARS && self.p1 >= self.p2 &&
    self.p2 >= self.p3 &&
    self.p3 >= self.p4 &&
    self.p4 >= self.p5 &&
    self.p5 >= self.p6 &&
    self.p6 >= self.p7 &&
    self.p7 >= self.p8 &&
    self.p8 >= self.p9 &&
    self.p9 >= self.p10 &&
    self.p10 >= self.pRest &&
    self.pRest >= MIN_NAME_PRICE;
}

fun PriceConfig.priceForCharCount(self, n: int): coins {
    if (n <= 1) {
        return self.p1;
    }
    if (n == 2) {
        return self.p2;
    }
    if (n == 3) {
        return self.p3;
    }
    if (n == 4) {
        return self.p4;
    }
    if (n == 5) {
        return self.p5;
    }
    if (n == 6) {
        return self.p6;
    }
    if (n == 7) {
        return self.p7;
    }
    if (n == 8) {
        return self.p8;
    }
    if (n == 9) {
        return self.p9;
    }
    if (n == 10) {
        return self.p10;
    }
    return self.pRest; // 11+
}

// Default preset (4-char minimum). p1..p3 are premium tiers, unused at minChars 4 but kept monotonic.
fun defaultPriceConfig(): PriceConfig {
    return {
        minChars: 4,
        p1: ton("100"),
        p2: ton("50"),
        p3: ton("20"),
        p4: ton("10"),
        p5: ton("5"),
        p6: ton("4"),
        p7: ton("3"),
        p8: ton("2"),
        p9: ton("1"),
        p10: ton("0.5"),
        pRest: ton("0.1"),
    };
}
