import "@contracts/prices"

fun defaultPriceConfig(): PriceConfig {
    return {
        minChars: 4,
        p1: grams("100"),
        p2: grams("50"),
        p3: grams("20"),
        p4: grams("10"),
        p5: grams("5"),
        p6: grams("4"),
        p7: grams("3"),
        p8: grams("2"),
        p9: grams("1"),
        p10: grams("0.5"),
        pRest: grams("0.1"),
    };
}
