import "@stdlib/strings"
// Prepare locally first, then broadcast only with every printed input pinned through env vars.
import "@acton/build"
import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@contracts/SubdomainFactory"
import "@wrappers/SubdomainFactory.gen"

fun requireDeploy(condition: bool, message: string) {
    if (!condition) {
        println("DEPLOY_ABORT={}", message);
        throw 901;
    }
}

const MAINNET_GLOBAL_ID = -239

// Script-only network attestation. Unlike a caller-provided env label, GLOBALID comes from the C7
// network configuration selected by Acton's actual `--net` target.
// SAFETY: GLOBALID is a read-only TVM instruction with no stack inputs and one integer output.
fun currentGlobalId(): int
    asm "GLOBALID"

fun main() {
    val walletName = "prod-deployer";
    val deployer = scripts.wallet("prod-deployer");
    val initialStorage: FactoryStorage = { pending: [] };
    val factory = SubdomainFactory.fromStorage(initialStorage);

    val factoryCodeHash = build("SubdomainFactory").hash();
    val collectionCodeHash = build("SubdomainCollection").hash();
    val itemCodeHash = build("SubdomainItem").hash();
    val storageHash = initialStorage.toCell().hash();
    val declaredNetwork = env<string>("DEPLOY_NETWORK") ?? "emulation";
    val vmGlobalId = currentGlobalId();
    val deployValue = ton("0.1");

    println("DEPLOY_BROADCAST={}", net.isBroadcasting());
    println("DEPLOY_NETWORK={}", declaredNetwork);
    println("DEPLOY_VM_GLOBAL_ID={}", vmGlobalId);
    println("DEPLOY_WALLET_NAME={}", walletName);
    println("DEPLOY_WALLET_ADDRESS={}", deployer.address);
    println("DEPLOY_FACTORY_ADDRESS={}", factory.address);
    println("DEPLOY_FACTORY_CODE_HASH=0x{:x}", factoryCodeHash);
    println("DEPLOY_COLLECTION_CODE_HASH=0x{:x}", collectionCodeHash);
    println("DEPLOY_ITEM_CODE_HASH=0x{:x}", itemCodeHash);
    println("DEPLOY_INITIAL_STORAGE_HASH=0x{:x}", storageHash);
    println("DEPLOY_VALUE={}", deployValue);

    if (net.isBroadcasting()) {
        requireDeploy(
            declaredNetwork.equalTo("mainnet"),
            "this release script is mainnet-only; DEPLOY_NETWORK must be mainnet",
        );
        requireDeploy(
            vmGlobalId == MAINNET_GLOBAL_ID,
            "VM GLOBALID is not the mainnet value",
        );
        val expectedWallet = env<address>("EXPECTED_DEPLOYER_ADDRESS");
        val expectedFactory = env<address>("EXPECTED_FACTORY_ADDRESS");
        val expectedFactoryHash = env<int>("EXPECTED_FACTORY_CODE_HASH");
        val expectedCollectionHash = env<int>("EXPECTED_COLLECTION_CODE_HASH");
        val expectedItemHash = env<int>("EXPECTED_ITEM_CODE_HASH");
        val expectedStorageHash = env<int>("EXPECTED_INITIAL_STORAGE_HASH");

        requireDeploy(expectedWallet != null, "EXPECTED_DEPLOYER_ADDRESS is required");
        requireDeploy(expectedFactory != null, "EXPECTED_FACTORY_ADDRESS is required");
        requireDeploy(expectedFactoryHash != null, "EXPECTED_FACTORY_CODE_HASH is required");
        requireDeploy(expectedCollectionHash != null, "EXPECTED_COLLECTION_CODE_HASH is required");
        requireDeploy(expectedItemHash != null, "EXPECTED_ITEM_CODE_HASH is required");
        requireDeploy(expectedStorageHash != null, "EXPECTED_INITIAL_STORAGE_HASH is required");
        requireDeploy(expectedWallet! == deployer.address, "deployer address mismatch");
        requireDeploy(expectedFactory! == factory.address, "factory address mismatch");
        requireDeploy(expectedFactoryHash! == factoryCodeHash, "factory code hash mismatch");
        requireDeploy(
            expectedCollectionHash! == collectionCodeHash,
            "collection code hash mismatch",
        );
        requireDeploy(expectedItemHash! == itemCodeHash, "item code hash mismatch");
        requireDeploy(expectedStorageHash! == storageHash, "initial storage hash mismatch");
        requireDeploy(
            env<bool>("CONFIRM_FACTORY_DEPLOY") ?? false,
            "set CONFIRM_FACTORY_DEPLOY=true after reviewing every printed input",
        );
        requireDeploy(
            env<bool>("CONFIRM_MAINNET") ?? false,
            "set CONFIRM_MAINNET=true for an irreversible mainnet deployment",
        );
    }

    if (scripts.isContractDeployed(factory.address)) {
        println("DEPLOY_ABORT=factory address is already active");
        return;
    }

    println("Deploying SubdomainFactory from {}", deployer.address);
    val res = factory.deploy(deployer.address, { value: deployValue, bounce: false });
    if (res.waitForFirstTransaction() == null) {
        println("Factory deployment was not confirmed");
        return;
    }

    println("FACTORY_ADDRESS={}", factory.address);
}
