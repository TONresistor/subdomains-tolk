// Renew a collection's parent .ton lease (anti dns_balance_release). Run on a cron (e.g. monthly).
// Anyone can run this, including subdomain holders protecting their own names.
// Run: COLLECTION_ADDRESS=... acton script scripts/keep-alive.tolk
import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"

fun main() {
    val keeper = scripts.wallet("prod-deployer");

    val collectionAddress: address? = env("COLLECTION_ADDRESS");
    if (collectionAddress == null) {
        println("Set COLLECTION_ADDRESS.");
        return;
    }

    val coll = SubdomainCollection.fromAddress(collectionAddress!);
    println("Last parent fill-up (unix): {}", coll.getLastParentFillUp());

    val res = coll.sendFillUpParent(
        keeper.address,
        1,
        { value: MIN_PARENT_FILL, bounce: true },
    );
    if (res.waitForFirstTransaction() == null) {
        println("Renew was not confirmed");
        return;
    }

    println("Parent lease renewed. New last fill-up (unix): {}", coll.getLastParentFillUp());
}
