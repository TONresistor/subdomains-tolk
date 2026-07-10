import "@stdlib/strings"
import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@wrappers/SubdomainFactory.gen"

const MAINNET_GLOBAL_ID = -239

// SAFETY: GLOBALID is a read-only TVM instruction with no stack inputs and one integer output.
fun currentGlobalId(): int
    asm "GLOBALID"

fun requireRetry(condition: bool, message: string) {
    if (!condition) {
        println("RETRY_ABORT={}", message);
        throw 902;
    }
}

// Phase-aware recovery for a pending collection deployment. The pending admin must run this with
// their own configured Acton wallet. 0.5 TON covers both the deploy phase and the larger final
// handoff recovery phase; unused deploy-phase value is refunded by the factory.
fun main() {
    val walletName = env<string>("RETRY_WALLET_NAME") ?? "prod-deployer";
    val admin = scripts.wallet(walletName);
    val factoryAddress = env<address>("RETRY_FACTORY_ADDRESS");
    val collectionAddress = env<address>("RETRY_COLLECTION_ADDRESS");
    val queryId = env<int>("RETRY_QUERY_ID") ?? blockchain.logicalTime();
    val declaredNetwork = env<string>("RETRY_NETWORK") ?? "emulation";
    val vmGlobalId = currentGlobalId();
    val retryValue = ton("0.5");

    println("RETRY_BROADCAST={}", net.isBroadcasting());
    println("RETRY_NETWORK={}", declaredNetwork);
    println("RETRY_VM_GLOBAL_ID={}", vmGlobalId);
    println("RETRY_WALLET_NAME={}", walletName);
    println("RETRY_ADMIN_ADDRESS={}", admin.address);
    println("RETRY_FACTORY_ADDRESS={}", factoryAddress);
    println("RETRY_COLLECTION_ADDRESS={}", collectionAddress);
    println("RETRY_QUERY_ID={}", queryId);
    println("RETRY_VALUE={}", retryValue);

    requireRetry(factoryAddress != null, "RETRY_FACTORY_ADDRESS is required");
    requireRetry(collectionAddress != null, "RETRY_COLLECTION_ADDRESS is required");
    if (!net.isBroadcasting()) {
        println("RETRY_PREPARED=true");
        return;
    }

    requireRetry(
        declaredNetwork.equalTo("mainnet"),
        "this release recovery script is mainnet-only; RETRY_NETWORK must be mainnet",
    );
    requireRetry(
        vmGlobalId == MAINNET_GLOBAL_ID,
        "VM GLOBALID is not the mainnet value",
    );
    val expectedAdmin = env<address>("EXPECTED_RETRY_ADMIN_ADDRESS");
    requireRetry(expectedAdmin != null, "EXPECTED_RETRY_ADMIN_ADDRESS is required");
    requireRetry(expectedAdmin! == admin.address, "pending admin address mismatch");
    requireRetry(
        env<bool>("CONFIRM_COLLECTION_RETRY") ?? false,
        "set CONFIRM_COLLECTION_RETRY=true after reviewing every printed input",
    );
    requireRetry(
        env<bool>("CONFIRM_MAINNET") ?? false,
        "set CONFIRM_MAINNET=true for an irreversible mainnet retry",
    );

    val factory = SubdomainFactory.fromAddress(factoryAddress!);
    val result = factory.sendRetryCollectionDeployment(
        admin.address,
        queryId,
        collectionAddress!,
        { value: retryValue, bounce: true },
    );
    if (result.waitForFirstTransaction() == null) {
        println("RETRY_CONFIRMED=false");
        return;
    }
    println("RETRY_CONFIRMED=true");
}
