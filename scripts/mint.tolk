// Mint a subdomain on a locked collection.
// Run: COLLECTION_ADDRESS=... LABEL=alice acton script scripts/mint.tolk
import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@contracts/dns-utils"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"

fun main() {
    val minter = scripts.wallet("prod-deployer");

    val collectionAddress: address? = env("COLLECTION_ADDRESS");
    val label: string? = env("LABEL");

    if (collectionAddress == null || label == null) {
        println("Set COLLECTION_ADDRESS and LABEL.");
        return;
    }

    val coll = SubdomainCollection.fromAddress(collectionAddress!);

    val charCount = label!.beginParse().remainingBitsCount() / BYTE_SIZE;
    val price = coll.getPrice(charCount);
    val sendValue = price + ITEM_DEPLOY_COST + MINT_FEE_BUFFER;

    val itemAddr = coll.getNftAddressByIndex(label!.beginParse().hash());
    println(
        "Label {} ({} chars): price {}, send {}, item at {}",
        label!,
        charCount,
        price,
        sendValue,
        itemAddr,
    );

    val res = coll.sendRegisterSubdomain(
        minter.address,
        1,
        label!.beginParse(),
        true,
        null,
        { value: sendValue, bounce: true },
    );
    if (res.waitForFirstTransaction() == null) {
        println("register was not confirmed");
        return;
    }

    println("Minted {}, NFT item at {}", label!, itemAddr);
}
