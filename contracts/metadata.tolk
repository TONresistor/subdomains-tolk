// Bounded complete TEP-64 metadata stored immutably at creation.
import "dns-utils"
import "errors"

const MAX_METADATA_CELLS = 32
const MAX_METADATA_BITS = 16384

fun assertOnchainMetadata(content: cell) {
    var root = content.beginParse();
    assert (root.remainingBitsCount() >= BYTE_SIZE) throw ERROR_METADATA_INVALID;
    assert (root.loadUint(BYTE_SIZE) == 0) throw ERROR_METADATA_INVALID;

    val (cells, bits, _, complete) = content.calculateSize(MAX_METADATA_CELLS);
    assert (complete) throw ERROR_METADATA_TOO_LARGE;
    assert (
        cells! <= MAX_METADATA_CELLS && bits! <= MAX_METADATA_BITS
    ) throw ERROR_METADATA_TOO_LARGE;

    assert (root.remainingBitsCount() >= 1) throw ERROR_METADATA_INVALID;
    val hasFields = root.preloadUint(1);
    assert (hasFields == 0 || root.remainingRefsCount() >= 1) throw ERROR_METADATA_INVALID;
    val _fields = root.loadDict();
    assert (root.isEmpty()) throw ERROR_METADATA_INVALID;
}
