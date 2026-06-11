// Deploy the global SubdomainFactory (Tier 0). Run: acton script scripts/deploy-factory.tolk
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "../wrappers/SubdomainFactory.gen"

fun main() {
    val deployer = scripts.wallet("prod-deployer");

    val factory = SubdomainFactory.fromStorage({ deployedCount: 0 });

    println("Deploying SubdomainFactory from {}", deployer.address);
    val res = factory.deploy(deployer.address, { value: ton("0.1"), bounce: false });
    if (res.waitForFirstTransaction() == null) {
        println("Factory deployment was not confirmed");
        return;
    }

    println("FACTORY_ADDRESS={}", factory.address);
    println("Deployed collections: {}", factory.getDeployedCount());
}
