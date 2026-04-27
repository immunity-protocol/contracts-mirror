// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMirror} from "./interfaces/IMirror.sol";
import {AntibodyLib} from "./libraries/Antibody.sol";

/// @title Mirror
/// @notice Per-chain replica of the 0G Registry's antibody envelopes.
///         Hot-path consumer is the v4 BeforeSwap hook, which reads
///         `isBlocked(address)` for sender / tx.origin / token0 / token1
///         on every swap.
contract Mirror is IMirror {
    address public admin;
    mapping(address => bool) public authorizedRelayers;
    mapping(bytes32 => AntibodyLib.Antibody) private _antibodies;
    mapping(address => bytes32) public blockedByAntibody;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyRelayer() {
        if (!authorizedRelayers[msg.sender]) revert NotRelayer();
        _;
    }

    constructor(address admin_, address initialRelayer) {
        if (admin_ == address(0) || initialRelayer == address(0)) revert ZeroAddress();
        admin = admin_;
        authorizedRelayers[initialRelayer] = true;
        emit AdminTransferred(address(0), admin_);
        emit RelayerSet(initialRelayer, true);
    }

    // ------------------------------------------------------------------
    //  Admin
    // ------------------------------------------------------------------

    function setRelayer(address relayer, bool authorized) external onlyAdmin {
        if (relayer == address(0)) revert ZeroAddress();
        authorizedRelayers[relayer] = authorized;
        emit RelayerSet(relayer, authorized);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    // ------------------------------------------------------------------
    //  Writes — stubbed; filled in by subsequent commits.
    // ------------------------------------------------------------------

    /// @inheritdoc IMirror
    /// @dev Idempotent: a second call with the same canonical fields
    ///      overwrites the slot in place. The keccakId is derived from
    ///      the struct (same algorithm as the Registry) — no need to
    ///      trust a relayer-supplied id.
    function mirrorAntibody(AntibodyLib.Antibody calldata a, bytes32 auxiliaryKey) external onlyRelayer {
        bytes32 keccakId = AntibodyLib.computeKeccakId(a);
        _antibodies[keccakId] = a;
        emit AntibodyMirrored(keccakId, a.publisher, a.abType);
        _emitAuxiliary(a.abType, a.flavor, keccakId, auxiliaryKey, a.publisher);
    }

    /// @dev Mirrors `Registry._emitAuxiliary` so per-type indexers see
    ///      the same event signatures across 0G and execution chains.
    function _emitAuxiliary(
        uint8 abType,
        uint8 flavor,
        bytes32 keccakId,
        bytes32 auxKey,
        address publisher
    ) internal {
        if (abType == uint8(AntibodyLib.AntibodyType.ADDRESS)) {
            emit AddressBlocked(address(uint160(uint256(auxKey))), keccakId, publisher);
        } else if (abType == uint8(AntibodyLib.AntibodyType.CALL_PATTERN)) {
            emit CallPatternBlocked(bytes4(auxKey), keccakId, publisher);
        } else if (abType == uint8(AntibodyLib.AntibodyType.BYTECODE)) {
            emit BytecodeBlocked(auxKey, keccakId, publisher);
        } else if (abType == uint8(AntibodyLib.AntibodyType.GRAPH)) {
            emit GraphTaintAdded(auxKey, keccakId, publisher);
        } else {
            // SEMANTIC — indexed key is flavor; auxKey is unused.
            emit SemanticPatternAdded(flavor, keccakId, publisher);
        }
    }

    /// @inheritdoc IMirror
    /// @dev Single-tx ADDRESS path. Emits exactly one `AddressBlocked`
    ///      event (vs two if the relayer called `mirrorAntibody` then
    ///      `setAddressBlock` separately) and saves a tx round-trip.
    function mirrorAddressAntibody(AntibodyLib.Antibody calldata a, address target) external onlyRelayer {
        if (target == address(0)) revert ZeroAddress();
        bytes32 keccakId = AntibodyLib.computeKeccakId(a);
        _antibodies[keccakId] = a;
        blockedByAntibody[target] = keccakId;
        emit AntibodyMirrored(keccakId, a.publisher, a.abType);
        emit AddressBlocked(target, keccakId, a.publisher);
    }

    /// @inheritdoc IMirror
    /// @dev Last-write-wins. Pass `bytes32(0)` to clear. Reverts if the
    ///      target keccakId has not been mirrored, so the emitted
    ///      `AddressBlocked.publisher` field is always populated and
    ///      consumers cannot end up with dangling pointers.
    function setAddressBlock(address target, bytes32 keccakId) external onlyRelayer {
        if (target == address(0)) revert ZeroAddress();
        if (keccakId == bytes32(0)) {
            blockedByAntibody[target] = bytes32(0);
            emit AddressBlocked(target, bytes32(0), address(0));
            return;
        }
        address publisher = _antibodies[keccakId].publisher;
        if (publisher == address(0)) revert AntibodyNotMirrored(keccakId);
        blockedByAntibody[target] = keccakId;
        emit AddressBlocked(target, keccakId, publisher);
    }

    function unmirrorAntibody(bytes32) external onlyRelayer {
        revert("not implemented");
    }

    // ------------------------------------------------------------------
    //  Reads — stubbed; filled in by subsequent commits.
    // ------------------------------------------------------------------

    function getAntibody(bytes32 keccakId) external view returns (AntibodyLib.Antibody memory) {
        return _antibodies[keccakId];
    }

    function isBlocked(address target) external view returns (bytes32) {
        return blockedByAntibody[target];
    }

    function getAntibodiesByPublisher(address) external pure returns (bytes32[] memory) {
        revert("not implemented");
    }
}
