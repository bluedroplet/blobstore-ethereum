pragma solidity ^0.4.0;

import "abstract_blobstore.sol";
import "blobstore_registry.sol";

/**
 * @title BlobStore
 * @author Jonathan Brown <jbrown@bluedroplet.com>
 */
contract BlobStore is AbstractBlobStore {

    /**
     * @dev Single slot structure of blob info.
     */
    struct BlobInfo {
        bool updatable;             // True if the blob is updatable. After creation can only be disabled.
        bool enforceRevisions;      // True if the blob is enforcing revisions. After creation can only be enabled.
        bool retractable;           // True if the blob can be retracted. After creation can only be disabled.
        bool transferable;          // True if the blob be transfered to another user or disowned. After creation can only be disabled.
        uint32 revisionCount;       // Number of revisions including revision 0.
        uint32 blockNumber;         // Block number which contains revision 0.
        address owner;              // Who owns this blob.
    }

    /**
     * @dev Mapping of blob ids to blob info.
     */
    mapping (bytes32 => BlobInfo) blobInfo;

    /**
     * @dev Mapping of blob ids to mapping of packed slots of eight 32-bit block numbers.
     */
    mapping (bytes32 => mapping (uint => bytes32)) packedBlockNumbers;

    /**
     * @dev Mapping of blob ids to mapping of transfer recipient addresses to enabled.
     */
    mapping (bytes32 => mapping (address => bool)) enabledTransfers;

    /**
     * @dev Id of this instance of BlobStore. Unique across all blockchains.
     */
    bytes12 contractId;

    /**
     * @dev A blob revision has been published.
     * @param blobId Id of the blob.
     * @param revisionId Id of the revision (the highest at time of logging).
     * @param blob Contents of the blob.
     */
    event logBlob(bytes32 indexed blobId, uint indexed revisionId, bytes blob);

    /**
     * @dev A revision has been retracted.
     * @param blobId Id of the blob.
     * @param revisionId Id of the revision.
     */
    event logRetractRevision(bytes32 indexed blobId, uint revisionId);

    /**
     * @dev An entire blob has been retracted. This cannot be undone.
     * @param blobId Id of the blob.
     */
    event logRetract(bytes32 indexed blobId);

    /**
     * @dev A blob has been transfered to a new address.
     * @param blobId Id of the blob.
     * @param recipient The address that now owns the blob.
     */
    event logTransfer(bytes32 indexed blobId, address recipient);

    /**
     * @dev A blob has been disowned. This cannot be undone.
     * @param blobId Id of the blob.
     */
    event logDisown(bytes32 indexed blobId);

    /**
     * @dev A blob has been set as not updatable. This cannot be undone.
     * @param blobId Id of the blob.
     */
    event logSetNotUpdatable(bytes32 indexed blobId);

    /**
     * @dev A blob has been set as enforcing revisions. This cannot be undone.
     * @param blobId Id of the blob.
     */
    event logSetEnforceRevisions(bytes32 indexed blobId);

    /**
     * @dev A blob has been set as not retractable. This cannot be undone.
     * @param blobId Id of the blob.
     */
    event logSetNotRetractable(bytes32 indexed blobId);

    /**
     * @dev A blob has been set as not transferable. This cannot be undone.
     * @param blobId Id of the blob.
     */
    event logSetNotTransferable(bytes32 indexed blobId);

    /**
     * @dev Throw if the blob has not been used before or it has been retracted.
     * @param blobId Id of the blob.
     */
    modifier exists(bytes32 blobId) {
        BlobInfo info = blobInfo[blobId];
        if (info.blockNumber == 0 || info.blockNumber == uint32(-1)) {
            throw;
        }
        _;
    }

    /**
     * @dev Throw if the owner of the blob is not the message sender.
     * @param blobId Id of the blob.
     */
    modifier isOwner(bytes32 blobId) {
        if (blobInfo[blobId].owner != msg.sender) {
            throw;
        }
        _;
    }

    /**
     * @dev Throw if the blob is not updatable.
     * @param blobId Id of the blob.
     */
    modifier isUpdatable(bytes32 blobId) {
        if (!blobInfo[blobId].updatable) {
            throw;
        }
        _;
    }

    /**
     * @dev Throw if the blob is not enforcing revisions.
     * @param blobId Id of the blob.
     */
    modifier isNotEnforceRevisions(bytes32 blobId) {
        if (blobInfo[blobId].enforceRevisions) {
            throw;
        }
        _;
    }

    /**
     * @dev Throw if the blob is not retractable.
     * @param blobId Id of the blob.
     */
    modifier isRetractable(bytes32 blobId) {
        if (!blobInfo[blobId].retractable) {
            throw;
        }
        _;
    }

    /**
     * @dev Throw if the blob is not transferable.
     * @param blobId Id of the blob.
     */
    modifier isTransferable(bytes32 blobId) {
        if (!blobInfo[blobId].transferable) {
            throw;
        }
        _;
    }

    /**
     * @dev Throw if the blob is not transferable to a specific user.
     * @param blobId Id of the blob.
     * @param recipient Address of the user.
     */
    modifier isTransferEnabled(bytes32 blobId, address recipient) {
        if (!enabledTransfers[blobId][recipient]) {
            throw;
        }
        _;
    }

    /**
     * @dev Throw if the blob only has one revision.
     * @param blobId Id of the blob.
     */
    modifier hasAdditionalRevisions(bytes32 blobId) {
        if (blobInfo[blobId].revisionCount == 1) {
            throw;
        }
        _;
    }

    /**
     * @dev Throw if a specific blob revision does not exist.
     * @param blobId Id of the blob.
     * @param revisionId Id of the revision.
     */
    modifier revisionExists(bytes32 blobId, uint revisionId) {
        if (revisionId >= blobInfo[blobId].revisionCount) {
            throw;
        }
        _;
    }

    /**
     * @dev Constructor.
     * @param registry Address of BlobStoreRegistry contract to register with.
     */
    function BlobStore(BlobStoreRegistry registry) {
        // Create id for this contract.
        contractId = bytes12(sha3(this, block.blockhash(block.number - 1)));
        // Register this contract.
        registry.register(contractId);
    }

    /**
     * @dev Stores new blob in the transaction log. It is guaranteed that each user will get a different id from the same nonce.
     * @param blob Blob that should be stored.
     * @param nonce Any value that the user has not used previously to create a blob.
     * @param updatable True if the blob should be updatable.
     * @param enforceRevisions True if the blob should enforce revisions.
     * @param retractable True if the blob should be retractable.
     * @param transferable True if the blob should be transferable.
     * @param anon True if the blob should be anonymous.
     * @return blobId Id of the blob.
     */
    function create(bytes blob, bytes32 nonce, bool updatable, bool enforceRevisions, bool retractable, bool transferable, bool anon) external returns (bytes32 blobId) {
        // Determine the blob id.
        blobId = contractId | (sha3(msg.sender, nonce) & (2 ** 160 - 1));
        // Make sure this blob id has not been used before.
        if (blobInfo[blobId].blockNumber != 0) {
            throw;
        }
        // Store blob info in state.
        blobInfo[blobId] = BlobInfo({
            updatable: updatable,
            enforceRevisions: enforceRevisions,
            retractable: retractable,
            transferable: transferable,
            revisionCount: 1,
            blockNumber: uint32(block.number),
            owner: anon ? 0 : msg.sender,
        });
        // Store the blob in a log in the current block.
        logBlob(blobId, 0, blob);
    }

    /**
     * @dev Store a blob revision block number in a packed slot.
     * @param blobId Id of the blob.
     * @param offset The offset of the block number should be retreived.
     */
    function _setPackedBlockNumber(bytes32 blobId, uint offset) internal {
        // Get the slot.
        bytes32 slot = packedBlockNumbers[blobId][offset / 8];
        // Wipe the previous block number.
        slot &= ~bytes32(uint32(-1) * 2 ** ((offset % 8) * 32));
        // Insert the current block number.
        slot |= bytes32(uint32(block.number) * 2 ** ((offset % 8) * 32));
        // Store the slot.
        packedBlockNumbers[blobId][offset / 8] = slot;
    }

    /**
     * @dev Create a new blob revision.
     * @param blobId Id of the blob.
     * @param blob Blob that should be stored as the new revision. Typically a VCDIFF of an earlier revision.
     * @return revisionId The new revisionId.
     */
    function createNewRevision(bytes32 blobId, bytes blob) isOwner(blobId) isUpdatable(blobId) external returns (uint revisionId) {
        // Increment the number of revisions.
        revisionId = blobInfo[blobId].revisionCount++;
        // Store the block number.
        _setPackedBlockNumber(blobId, revisionId - 1);
        // Store the new blob in a log in the current block.
        logBlob(blobId, revisionId, blob);
    }

    /**
     * @dev Update a blob's latest revision.
     * @param blobId Id of the blob.
     * @param blob Blob that should replace the latest revision. Typically a VCDIFF if there is an earlier revision.
     */
    function updateLatestRevision(bytes32 blobId, bytes blob) isOwner(blobId) isUpdatable(blobId) isNotEnforceRevisions(blobId) external {
        BlobInfo info = blobInfo[blobId];
        uint revisionId = info.revisionCount - 1;
        // Update the block number.
        if (revisionId == 0) {
            info.blockNumber = uint32(block.number);
        }
        else {
            _setPackedBlockNumber(blobId, revisionId - 1);
        }
        // Store the new blob in a log in the current block.
        logBlob(blobId, revisionId, blob);
    }

    /**
     * @dev Retract a blob's latest revision. Revision 0 cannot be retracted.
     * @param blobId Id of the blob.
     */
    function retractLatestRevision(bytes32 blobId) isOwner(blobId) isUpdatable(blobId) isNotEnforceRevisions(blobId) hasAdditionalRevisions(blobId) external {
        uint revisionId = --blobInfo[blobId].revisionCount;
        // Delete the slot if it is no longer required.
        if (revisionId % 8 == 1) {
            delete packedBlockNumbers[blobId][revisionId / 8];
        }
        // Log the retraction.
        logRetractRevision(blobId, revisionId);
    }

    /**
     * @dev Delete all of a blob's packed revision block numbers.
     * @param blobId Id of the blob.
     */
    function _deleteAllPackedRevisionBlockNumbers(bytes32 blobId) internal {
        // Determine how many slots should be deleted.
        // Block number of the first revision is stored in the blob info, so the first slot only needs to be deleted of there are at least 2 revisions.
        uint slotCount = (blobInfo[blobId].revisionCount + 6) / 8;
        // Delete the slots.
        for (uint i = 0; i < slotCount; i++) {
            delete packedBlockNumbers[blobId][i];
        }
    }

    /**
     * @dev Delete all a blob's revisions and replace it with a new blob.
     * @param blobId Id of the blob.
     * @param blob Blob that should be stored.
     */
    function restart(bytes32 blobId, bytes blob) isOwner(blobId) isUpdatable(blobId) isNotEnforceRevisions(blobId) external {
        // Delete the packed revision block numbers.
        _deleteAllPackedRevisionBlockNumbers(blobId);
        // Update the blob state info.
        BlobInfo info = blobInfo[blobId];
        info.revisionCount = 1;
        info.blockNumber = uint32(block.number);
        // Store the blob in a log in the current block.
        logBlob(blobId, 0, blob);
    }

    /**
     * @dev Retract a blob.
     * @param blobId Id of the blob. This id can never be used again.
     */
    function retract(bytes32 blobId) isOwner(blobId) isRetractable(blobId) external {
        // Delete the packed revision block numbers.
        _deleteAllPackedRevisionBlockNumbers(blobId);
        // Mark this blob as retracted.
        blobInfo[blobId] = BlobInfo({
            updatable: false,
            enforceRevisions: false,
            retractable: false,
            transferable: false,
            revisionCount: 0,
            blockNumber: uint32(-1),
            owner: 0,
        });
        // Log that the blob has been retracted.
        logRetract(blobId);
    }

    /**
     * @dev Enable transfer of the blob to the current user.
     * @param blobId Id of the blob.
     */
    function transferEnable(bytes32 blobId) isTransferable(blobId) external {
        // Record in state that the current user will accept this blob.
        enabledTransfers[blobId][msg.sender] = true;
    }

    /**
     * @dev Disable transfer of the blob to the current user.
     * @param blobId Id of the blob.
     */
    function transferDisable(bytes32 blobId) isTransferEnabled(blobId, msg.sender) external {
        // Record in state that the current user will not accept this blob.
        enabledTransfers[blobId][msg.sender] = false;
    }

    /**
     * @dev Transfer a blob to a new user.
     * @param blobId Id of the blob.
     * @param recipient Address of the user to transfer to blob to.
     */
    function transfer(bytes32 blobId, address recipient) isOwner(blobId) isTransferable(blobId) isTransferEnabled(blobId, recipient) external {
        // Update ownership of the blob.
        blobInfo[blobId].owner = recipient;
        // Disable this transfer in future and free up the slot.
        enabledTransfers[blobId][recipient] = false;
        // Log the transfer.
        logTransfer(blobId, recipient);
    }

    /**
     * @dev Disown a blob.
     * @param blobId Id of the blob.
     */
    function disown(bytes32 blobId) isOwner(blobId) isTransferable(blobId) external {
        // Remove the owner from the blob's state.
        delete blobInfo[blobId].owner;
        // Log as blob as disowned.
        logDisown(blobId);
    }

    /**
     * @dev Set a blob as not updatable.
     * @param blobId Id of the blob.
     */
    function setNotUpdatable(bytes32 blobId) isOwner(blobId) external {
        // Record in state that the blob is not updatable.
        blobInfo[blobId].updatable = false;
        // Log that the blob is not updatable.
        logSetNotUpdatable(blobId);
    }

    /**
     * @dev Set a blob to enforce revisions.
     * @param blobId Id of the blob.
     */
    function setEnforceRevisions(bytes32 blobId) isOwner(blobId) external {
        // Record in state that all changes to this blob must be new revisions.
        blobInfo[blobId].enforceRevisions = true;
        // Log that the blob now forces new revisions.
        logSetEnforceRevisions(blobId);
    }

    /**
     * @dev Set a blob to not be retractable.
     * @param blobId Id of the blob.
     */
    function setNotRetractable(bytes32 blobId) isOwner(blobId) external {
        // Record in state that the blob is not retractable.
        blobInfo[blobId].retractable = false;
        // Log that the blob is not retractable.
        logSetNotRetractable(blobId);
    }

    /**
     * @dev Set a blob to not be transferable.
     * @param blobId Id of the blob.
     */
    function setNotTransferable(bytes32 blobId) isOwner(blobId) external {
        // Record in state that the blob is not transferable.
        blobInfo[blobId].transferable = false;
        // Log that the blob is not transferable.
        logSetNotTransferable(blobId);
    }

    /**
     * @dev Get the id for this BlobStore contract.
     * @return Id of the contract.
     */
    function getContractId() constant external returns (bytes12) {
        return contractId;
    }

    /**
     * @dev Check if a blob exists.
     * @param blobId Id of the blob.
     * @return exists True if the blob exists.
     */
    function getExists(bytes32 blobId) constant external returns (bool exists) {
        BlobInfo info = blobInfo[blobId];
        exists = info.blockNumber != 0 && info.blockNumber != uint32(-1);
    }

    /**
     * @dev Get the block number for a specific blob revision.
     * @param blobId Id of the blob.
     * @param revisionId Id of the revision.
     * @return blockNumber Block number of the specified revision.
     */
    function _getRevisionBlockNumber(bytes32 blobId, uint revisionId) internal returns (uint blockNumber) {
        if (revisionId == 0) {
            blockNumber = blobInfo[blobId].blockNumber;
        }
        else {
            bytes32 slot = packedBlockNumbers[blobId][(revisionId - 1) / 8];
            blockNumber = uint32(uint256(slot) / 2 ** (((revisionId - 1) % 8) * 32));
        }
    }

    /**
     * @dev Get the block numbers for all of a blob's revisions.
     * @param blobId Id of the blob.
     * @return blockNumbers Revision block numbers.
     */
    function _getAllRevisionBlockNumbers(bytes32 blobId) internal returns (uint[] blockNumbers) {
        uint revisionCount = blobInfo[blobId].revisionCount;
        blockNumbers = new uint[](revisionCount);
        for (uint revisionId = 0; revisionId < revisionCount; revisionId++) {
            blockNumbers[revisionId] = _getRevisionBlockNumber(blobId, revisionId);
        }
    }

    /**
     * @dev Get info about a blob.
     * @param blobId Id of the blob.
     * @return owner Owner of the blob.
     * @return revisionCount How many revisions the blob has.
     * @return blockNumbers The block numbers of the revisions.
     * @return updatable Is the blob updatable?
     * @return enforceRevisions Does the blob enforce revisions?
     * @return retractable Is the blob retractable?
     * @return transferable Is the blob transferable?
     */
    function getInfo(bytes32 blobId) exists(blobId) constant external returns (address owner, uint revisionCount, uint[] blockNumbers, bool updatable, bool enforceRevisions, bool retractable, bool transferable) {
        BlobInfo info = blobInfo[blobId];
        owner = info.owner;
        revisionCount = info.revisionCount;
        blockNumbers = _getAllRevisionBlockNumbers(blobId);
        updatable = info.updatable;
        enforceRevisions = info.enforceRevisions;
        retractable = info.retractable;
        transferable = info.transferable;
    }

    /**
     * @dev Get the owner of a blob.
     * @param blobId Id of the blob.
     * @return owner Owner of the blob.
     */
    function getOwner(bytes32 blobId) exists(blobId) constant external returns (address owner) {
        owner = blobInfo[blobId].owner;
    }

    /**
     * @dev Get the number of revisions a blob has.
     * @param blobId Id of the blob.
     * @return revisionCount How many revisions the blob has.
     */
    function getRevisionCount(bytes32 blobId) exists(blobId) constant external returns (uint revisionCount) {
        revisionCount = blobInfo[blobId].revisionCount;
    }

    /**
     * @dev Get the block number for a specific blob revision.
     * @param blobId Id of the blob.
     * @param revisionId Id of the revision.
     * @return blockNumber Block number of the specified revision.
     */
    function getRevisionBlockNumber(bytes32 blobId, uint revisionId) constant external returns (uint blockNumber) {
        blockNumber = _getRevisionBlockNumber(blobId, revisionId);
    }

    /**
     * @dev Get the block numbers for all of a blob's revisions.
     * @param blobId Id of the blob.
     * @return blockNumbers Revision block numbers.
     */
    function getAllRevisionBlockNumbers(bytes32 blobId) exists(blobId) constant external returns (uint[] blockNumbers) {
        blockNumbers = _getAllRevisionBlockNumbers(blobId);
    }

    /**
     * @dev Determine if a blob is updatable.
     * @param blobId Id of the blob.
     * @return updatable True if the blob is updatable.
     */
    function getUpdatable(bytes32 blobId) exists(blobId) constant external returns (bool updatable) {
        updatable = blobInfo[blobId].updatable;
    }

    /**
     * @dev Determine if a blob enforces revisions.
     * @param blobId Id of the blob.
     * @return enforceRevisions True if the blob enforces revisions.
     */
    function getEnforceRevisions(bytes32 blobId) exists(blobId) constant external returns (bool enforceRevisions) {
        enforceRevisions = blobInfo[blobId].enforceRevisions;
    }

    /**
     * @dev Determine if a blob is retractable.
     * @param blobId Id of the blob.
     * @return retractable True if the blob is blob retractable.
     */
    function getRetractable(bytes32 blobId) exists(blobId) constant external returns (bool retractable) {
        retractable = blobInfo[blobId].retractable;
    }

    /**
     * @dev Determine if a blob is transferable.
     * @param blobId Id of the blob.
     * @return transferable True if the blob is transferable.
     */
    function getTransferable(bytes32 blobId) exists(blobId) constant external returns (bool transferable) {
        transferable = blobInfo[blobId].transferable;
    }

}
