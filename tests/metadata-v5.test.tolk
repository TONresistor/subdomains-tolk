import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "@contracts/dns-utils"
import "@contracts/errors"
import "@contracts/messages"
import "@contracts/metadata"
import "@contracts/storage"
import "@wrappers/SubdomainCollection.gen"
import "@wrappers/SubdomainFactory.gen"
import "@wrappers/SubdomainItem.gen"
import "test-utils"

fun oversizedMetadata(): cell {
    var tail = beginCell().endCell();
    repeat (MAX_METADATA_CELLS + 1) {
        tail = beginCell().storeRef(tail).endCell();
    }
    return beginCell().storeUint(0, BYTE_SIZE).storeRef(tail).endCell();
}

fun bitHeavyMetadata(): cell {
    var tail = beginCell()
        .storeUint(0, 256)
        .storeUint(0, 256)
        .storeUint(0, 256)
        .storeUint(0, 255)
        .endCell();
    repeat (17) {
        tail = beginCell()
            .storeUint(0, 256)
            .storeUint(0, 256)
            .storeUint(0, 256)
            .storeUint(0, 255)
            .storeRef(tail)
            .endCell();
    }
    return beginCell().storeUint(0, BYTE_SIZE).storeRef(tail).endCell();
}

fun nearLimitMetadata(): cell {
    var tail = beginCell()
        .storeUint(0, 250)
        .storeUint(0, 250)
        .storeUint(0, 250)
        .storeUint(0, 250)
        .endCell();
    repeat (13) {
        tail = beginCell()
            .storeUint(0, 250)
            .storeUint(0, 250)
            .storeUint(0, 250)
            .storeUint(0, 250)
            .storeRef(tail)
            .endCell();
    }
    val snake = beginCell()
        .storeUint(0, BYTE_SIZE)
        .storeUint(0, 248)
        .storeUint(0, 248)
        .storeUint(0, 248)
        .storeUint(0, 248)
        .storeRef(tail)
        .endCell();
    var fields: map<uint256, cell> = [];
    fields.set(
        0x82a3537ff0dbce7eec35d69edc3a189ee6f17d82f353a553f9aa96cb0be3ce89,
        snake,
    );
    return beginCell().storeUint(0, BYTE_SIZE).storeDict(fields.toLowLevelDict()).endCell();
}

fun expectLinkedMetadataFailure(
    factory: SubdomainFactory,
    owner: address,
    parent: address,
    queryId: uint64,
    content: cell,
    exitCode: int,
) {
    var meta = makeMeta();
    meta.collectionContent = content;
    val result = factory.sendCreateLinkedCollection(
        owner,
        queryId,
        parent,
        owner,
        meta,
        { value: ton("0.5"), bounce: true },
    );
    expect(result).toHaveFailedTx({ to: factory.address, exitCode });
}

get fun `test v5 metadata: validation reports exact tag and size failures`() {
    var emptyExit = 0;
    try {
        assertOnchainMetadata(beginCell().endCell());
    } catch (exitCode) {
        emptyExit = exitCode;
    }
    expect(emptyExit).toEqual(ERROR_METADATA_INVALID);

    var tagExit = 0;
    try {
        assertOnchainMetadata(beginCell().storeUint(1, BYTE_SIZE).endCell());
    } catch (exitCode) {
        tagExit = exitCode;
    }
    expect(tagExit).toEqual(ERROR_METADATA_INVALID);

    var missingDictionaryExit = 0;
    try {
        assertOnchainMetadata(beginCell().storeUint(0, BYTE_SIZE).endCell());
    } catch (exitCode) {
        missingDictionaryExit = exitCode;
    }
    expect(missingDictionaryExit).toEqual(ERROR_METADATA_INVALID);

    var trailingDataExit = 0;
    try {
        assertOnchainMetadata(
            beginCell().storeUint(0, BYTE_SIZE).storeBool(false).storeBool(false).endCell(),
        );
    } catch (exitCode) {
        trailingDataExit = exitCode;
    }
    expect(trailingDataExit).toEqual(ERROR_METADATA_INVALID);

    var missingDictionaryRefExit = 0;
    try {
        assertOnchainMetadata(beginCell().storeUint(0, BYTE_SIZE).storeBool(true).endCell());
    } catch (exitCode) {
        missingDictionaryRefExit = exitCode;
    }
    expect(missingDictionaryRefExit).toEqual(ERROR_METADATA_INVALID);

    var cellsExit = 0;
    try {
        assertOnchainMetadata(oversizedMetadata());
    } catch (exitCode) {
        cellsExit = exitCode;
    }
    expect(cellsExit).toEqual(ERROR_METADATA_TOO_LARGE);

    var bitsExit = 0;
    try {
        assertOnchainMetadata(bitHeavyMetadata());
    } catch (exitCode) {
        bitsExit = exitCode;
    }
    expect(bitsExit).toEqual(ERROR_METADATA_TOO_LARGE);
}

get fun `test v5 metadata: arbitrary collection content is accepted and immutable`() {
    val owner = newActor("metadata-factory-owner");
    val parent = newActor("metadata-factory-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    var meta = makeMeta();
    meta.collectionContent = testOnchainMetadataVariant();
    val created = factory.sendCreateLinkedCollection(
        owner.address,
        1,
        parent.address,
        owner.address,
        meta,
        { value: ton("0.5"), bounce: true },
    );
    expect(created).toHaveSuccessfulTx({ to: factory.address });

    val collection = SubdomainCollection.fromAddress(
        factory.getLinkedCollectionAddress(parent.address, owner.address),
    );
    expect(collection.getCollectionData().content.hash()).toEqual(meta.collectionContent.hash());
}

get fun `test v5 metadata: near-limit collection content deploys at exact funding`() {
    val owner = newActor("metadata-exact-owner");
    val linkedParent = newActor("metadata-exact-linked-parent");
    val lockedParent = newActor("metadata-exact-locked-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    var meta = makeMeta();
    meta.collectionContent = nearLimitMetadata();
    val linked = factory.sendCreateLinkedCollection(
        owner.address,
        20,
        linkedParent.address,
        owner.address,
        meta,
        { value: COLLECTION_DEPLOY_VALUE + FACTORY_GAS_MARGIN, bounce: true },
    );
    expect(linked).toHaveSuccessfulTx({ to: factory.address });
    expect(
        testing.isDeployed(factory.getLinkedCollectionAddress(linkedParent.address, owner.address)),
    ).toEqual(true);

    val locked = factory.sendOwnershipAssigned(
        lockedParent.address,
        21,
        owner.address,
        beginCell().storeRef(meta.toCell()).endCell().beginParse(),
        { value: MIN_CREATE_VALUE, bounce: false },
    );
    expect(locked).toHaveSuccessfulTx({ to: factory.address });
    expect(testing.isDeployed(factory.getCollectionAddress(lockedParent.address))).toEqual(true);
}

get fun `test v5 metadata: independent frontends can mint different immutable content`() {
    val (collection, _parent, _owner, firstMinter) = deployLockedCollection();
    val secondMinter = newActor("metadata-second-frontend");
    val firstContent = testOnchainMetadata();
    val secondContent = testOnchainMetadataVariant();

    val first = collection.sendRegisterSubdomain(
        firstMinter.address,
        2,
        labelSlice("alice"),
        true,
        firstContent,
        { value: ton("20"), bounce: true },
    );
    val firstDeploy = first.findTransaction({ from: collection.address, deploy: true });
    expect(firstDeploy).toBeNotNull();

    val second = collection.sendRegisterSubdomain(
        secondMinter.address,
        3,
        labelSlice("bobby"),
        true,
        secondContent,
        { value: ton("20"), bounce: true },
    );
    val secondDeploy = second.findTransaction({ from: collection.address, deploy: true });
    expect(secondDeploy).toBeNotNull();

    val firstItem = SubdomainItem.fromAddress(firstDeploy!.getAccountAddress());
    val secondItem = SubdomainItem.fromAddress(secondDeploy!.getAccountAddress());
    val firstNft = firstItem.getNftData();
    val secondNft = secondItem.getNftData();
    expect(firstNft.content!.hash()).toEqual(firstContent.hash());
    expect(secondNft.content!.hash()).toEqual(secondContent.hash());
    expect(
        collection.getNftContent(labelIndex("alice"), firstNft.content!).hash(),
    ).toEqual(firstContent.hash());
    expect(
        collection.getNftContent(labelIndex("bobby"), secondNft.content!).hash(),
    ).toEqual(secondContent.hash());
}

get fun `test v5 metadata: near-limit content mints at the exact quote`() {
    val (collection, _parent, _owner, minter) = deployLockedCollection();
    val content = nearLimitMetadata();
    assertOnchainMetadata(content);
    val quote = collection.getMintQuote(minter.address, 5);

    val underfunded = collection.sendRegisterSubdomain(
        minter.address,
        40,
        labelSlice("alice"),
        true,
        content,
        { value: quote.requiredValue - 1, bounce: true },
    );
    expect(underfunded).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_INSUFFICIENT_MINT_VALUE,
    });

    val minted = collection.sendRegisterSubdomain(
        minter.address,
        41,
        labelSlice("alice"),
        true,
        content,
        { value: quote.requiredValue, bounce: true },
    );
    expect(minted).toHaveSuccessfulTx({ to: collection.address });
    val item = SubdomainItem.fromAddress(collection.getNftAddressByIndex(labelIndex("alice")));
    expect(item.getNftData().content!.hash()).toEqual(content.hash());
}

get fun `test v5 metadata: invalid and oversized item content is rejected`() {
    val (collection, _parent, _owner, minter) = deployLockedCollection();

    val missingTag = collection.sendRegisterSubdomain(
        minter.address,
        4,
        labelSlice("alice"),
        true,
        beginCell().endCell(),
        { value: ton("20"), bounce: true },
    );
    expect(missingTag).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_METADATA_INVALID,
    });

    val offchain = collection.sendRegisterSubdomain(
        minter.address,
        5,
        labelSlice("bobby"),
        true,
        beginCell().storeUint(1, BYTE_SIZE).endCell(),
        { value: ton("20"), bounce: true },
    );
    expect(offchain).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_METADATA_INVALID,
    });

    val oversized = collection.sendRegisterSubdomain(
        minter.address,
        6,
        labelSlice("carol"),
        true,
        oversizedMetadata(),
        { value: ton("20"), bounce: true },
    );
    expect(oversized).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_METADATA_TOO_LARGE,
    });

    val bitHeavy = collection.sendRegisterSubdomain(
        minter.address,
        7,
        labelSlice("david"),
        true,
        bitHeavyMetadata(),
        { value: ton("20"), bounce: true },
    );
    expect(bitHeavy).toHaveFailedTx({
        to: collection.address,
        exitCode: ERROR_METADATA_TOO_LARGE,
    });
}

get fun `test v5 metadata: factory rejects invalid collection content`() {
    val owner = newActor("metadata-invalid-owner");
    val parent = newActor("metadata-invalid-parent");
    val factory = SubdomainFactory.fromStorage({ pending: [] });
    factory.deploy(owner.address, { value: ton("1"), bounce: false });

    expectLinkedMetadataFailure(
        factory,
        owner.address,
        parent.address,
        8,
        beginCell().endCell(),
        ERROR_METADATA_INVALID,
    );
    expectLinkedMetadataFailure(
        factory,
        owner.address,
        parent.address,
        9,
        beginCell().storeUint(1, BYTE_SIZE).endCell(),
        ERROR_METADATA_INVALID,
    );
    expectLinkedMetadataFailure(
        factory,
        owner.address,
        parent.address,
        10,
        beginCell().storeUint(0, BYTE_SIZE).endCell(),
        ERROR_METADATA_INVALID,
    );
    expectLinkedMetadataFailure(
        factory,
        owner.address,
        parent.address,
        11,
        beginCell().storeUint(0, BYTE_SIZE).storeBool(true).endCell(),
        ERROR_METADATA_INVALID,
    );
    expectLinkedMetadataFailure(
        factory,
        owner.address,
        parent.address,
        12,
        beginCell().storeUint(0, BYTE_SIZE).storeBool(false).storeBool(false).endCell(),
        ERROR_METADATA_INVALID,
    );
    expectLinkedMetadataFailure(
        factory,
        owner.address,
        parent.address,
        13,
        oversizedMetadata(),
        ERROR_METADATA_TOO_LARGE,
    );
    expectLinkedMetadataFailure(
        factory,
        owner.address,
        parent.address,
        14,
        bitHeavyMetadata(),
        ERROR_METADATA_TOO_LARGE,
    );

    var meta = makeMeta();
    meta.collectionContent = beginCell().storeUint(1, BYTE_SIZE).endCell();
    val locked = factory.sendOwnershipAssigned(
        parent.address,
        15,
        owner.address,
        beginCell().storeRef(meta.toCell()).endCell().beginParse(),
        { value: MIN_CREATE_VALUE, bounce: false },
    );
    expect(
        locked.findTransaction<TransferOwnership>({
            from: factory.address,
            to: parent.address,
        }),
    ).toBeNotNull();
    expect(testing.isDeployed(factory.getCollectionAddress(parent.address))).toEqual(false);
}
