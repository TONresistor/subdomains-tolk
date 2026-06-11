// Tier 0: global, free, permissionless, non-upgradeable.
import "@gen/SubdomainCollection.code"
import "errors"
import "messages"
import "prices"
import "storage"

struct FactoryStorage {
    deployedCount: uint64
}

fun FactoryStorage.load(): FactoryStorage {
    return FactoryStorage.fromCell(contract.getData());
}

fun FactoryStorage.save(self) {
    contract.setData(self.toCell());
}

contract SubdomainFactory {
    author: "tolk-subdomains"
    version: "1.0.0"
    description: "Global permissionless free 1-tx create relay: deploys one locked SubdomainCollection per parent domain."
    incomingMessages: AllowedFactoryMessage
    storage: FactoryStorage
}

type AllowedFactoryMessage = OwnershipAssigned

fun handOffNft(
    parentDomain: address,
    to: address,
    queryId: uint64,
    forwardAmount: coins,
    mode: int,
    value: coins = 0,
) {
    createMessage({
        bounce: false,
        dest: parentDomain,
        value,
        body: TransferOwnership {
            queryId,
            transferData: {
                newOwnerAddress: to,
                responseDestination: to,
                customPayload: null,
                forwardAmount,
                forwardPayload: beginCell().endCell().beginParse(),
            },
        },
    }).send(mode);
}

fun onBouncedMessage(in: InMessageBounced) {}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }

    if (in.body.remainingBitsCount() >= 32 && in.body.preloadUint(32) == 0xd53276db) {
        return;
    }

    val msg = lazy AllowedFactoryMessage.fromSlice(
        in.body,
        { throwIfOpcodeDoesNotMatch: ERROR_UNKNOWN_OP },
    );

    match (msg) {
        OwnershipAssigned => {
            val parentDomain = in.senderAddress;
            assert (msg.oldOwnerAddress != null) throw ERROR_NULL_OLD_OWNER;
            val admin = msg.oldOwnerAddress!;
            // NON-throwing: validate the admin's workchain HERE, before dispatching the .ton handoff.
            // A masterchain admin must take the refund path; throwing later (e.g. in the collection's
            // lock) would strand the already-handed-off .ton.
            val adminBasechain = admin.getWorkchain() == BASECHAIN;

            var payload = msg.payload;
            var metaCell = beginCell().endCell();
            var metaValid = false;
            if (payload.remainingRefsCount() > 0) {
                metaCell = payload.loadRef();
                try {
                    val parsed = CollectionMeta.fromCell(metaCell);
                    val grid = parsed.priceConfig.load();
                    metaValid = grid.isValid();
                } catch {
                    metaValid = false;
                }
            }

            if (in.valueCoins < MIN_CREATE_VALUE || !metaValid || !adminBasechain) {
                handOffNft(
                    parentDomain,
                    admin,
                    msg.queryId,
                    0,
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
                );
                return;
            }

            val collectionCode = subdomainCollectionCompiledCode();
            val collDeploy = calcDeployedCollection(
                contract.getAddress(),
                parentDomain,
                collectionCode,
            );
            val collAddr = collDeploy.calculateAddress();

            // bounce:true so a re-lock against an already-locked collection (re-onboard of a parent
            // whose collection already exists) bounces COLLECTION_DEPLOY_VALUE back instead of being absorbed.
            createMessage({
                bounce: true,
                dest: collDeploy,
                value: COLLECTION_DEPLOY_VALUE,
                body: LockCollection {
                    queryId: msg.queryId,
                    admin,
                    meta: metaCell as Cell<CollectionMeta>,
                },
            }).send(SEND_MODE_REGULAR);

            handOffNft(
                parentDomain,
                collAddr,
                msg.queryId,
                RESOLVER_PIN_FUND,
                SEND_MODE_REGULAR,
                in.valueCoins - COLLECTION_DEPLOY_VALUE - FACTORY_GAS_MARGIN,
            );

            var st = lazy FactoryStorage.load();
            st.deployedCount += 1;
            st.save();
        }

        else => throw ERROR_UNKNOWN_OP,
    }
}

// =========================== getters ===========================

get fun get_collection_address(parentDomain: address): address {
    return calcDeployedCollection(
        contract.getAddress(),
        parentDomain,
        subdomainCollectionCompiledCode(),
    ).calculateAddress();
}

get fun get_deployed_count(): int {
    return FactoryStorage.load().deployedCount;
}
