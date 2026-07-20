// Mint a subdomain on a locked collection.
// Run with any complete TEP-64 on-chain metadata cell.
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
    val content: cell? = env("CONTENT_BOC");

    if (collectionAddress == null || label == null || content == null) {
        println("Set COLLECTION_ADDRESS, LABEL and CONTENT_BOC.");
        return;
    }

    val coll = SubdomainCollection.fromAddress(collectionAddress!);

    val charCount = label!.beginParse().remainingBitsCount() / BYTE_SIZE;
    val quote = coll.getMintQuote(minter.address, charCount);
    if (!quote.allowed) {
        println("Mint is not allowed for {}", minter.address);
        return;
    }

    val itemAddr = coll.getNftAddressByIndex(label!.beginParse().hash());
    println(
        "Label {} ({} chars): price {}, send {}, item at {}",
        label!,
        charCount,
        quote.effectivePrice,
        quote.requiredValue,
        itemAddr,
    );

    val res = coll.sendRegisterSubdomain(
        minter.address,
        1,
        label!.beginParse(),
        true,
        content!,
        { value: quote.requiredValue, bounce: true },
    );
    if (res.waitForFirstTransaction() == null) {
        println("register was not confirmed");
        return;
    }

    println("Minted {}, NFT item at {}", label!, itemAddr);
}
