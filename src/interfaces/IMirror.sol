// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AntibodyLib} from "../libraries/Antibody.sol";

/// @title IMirror
/// @notice Per-chain replica of the 0G Registry's antibody envelopes.
///         Writes come from authorized relayer addresses; reads are open.
///         Address-block index is a hot-path lookup for the v4 hook.
interface IMirror {
    // ------------------------------------------------------------------
    //  Events — auxiliary signatures match the 0G Registry verbatim so
    //  indexers see uniform shapes across 0G and every execution chain.
    // ------------------------------------------------------------------

    event AntibodyMirrored(bytes32 indexed keccakId, address indexed publisher, uint8 indexed abType);
    event AntibodyUnmirrored(bytes32 indexed keccakId);

    event AddressBlocked(address indexed target, bytes32 indexed keccakId, address indexed publisher);
    event CallPatternBlocked(bytes4 indexed selector, bytes32 indexed keccakId, address indexed publisher);
    event BytecodeBlocked(bytes32 indexed bytecodeHash, bytes32 indexed keccakId, address indexed publisher);
    event GraphTaintAdded(bytes32 indexed taintSetId, bytes32 indexed keccakId, address indexed publisher);
    event SemanticPatternAdded(uint8 indexed flavor, bytes32 indexed keccakId, address indexed publisher);

    event RelayerSet(address indexed relayer, bool authorized);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    // ------------------------------------------------------------------
    //  Errors
    // ------------------------------------------------------------------

    error NotAdmin();
    error NotRelayer();
    error AntibodyNotMirrored(bytes32 keccakId);
    error ZeroAddress();

    // ------------------------------------------------------------------
    //  Writes (relayer)
    // ------------------------------------------------------------------

    /// @notice Mirror an antibody envelope and emit the type-specific
    ///         auxiliary event. Idempotent — a second call with the same
    ///         (abType, flavor, primaryMatcherHash, publisher) overwrites
    ///         in place.
    /// @param a            full envelope; keccakId is derived on-chain.
    /// @param auxiliaryKey type-dependent payload mirroring the
    ///                     Registry's `PublishParams.auxiliaryKey`. For
    ///                     SEMANTIC the parameter is unused — pass
    ///                     `bytes32(0)`.
    function mirrorAntibody(AntibodyLib.Antibody calldata a, bytes32 auxiliaryKey) external;

    /// @notice ADDRESS-type convenience: mirrors the envelope and writes
    ///         the address-block index in one tx.
    function mirrorAddressAntibody(AntibodyLib.Antibody calldata a, address target) external;

    /// @notice Last-write-wins on the address-block index.
    ///         Pass `bytes32(0)` to clear.
    function setAddressBlock(address target, bytes32 keccakId) external;

    /// @notice Drop the antibody envelope. Address-index entries pointing
    ///         at this keccakId are NOT swept — the relayer must clear
    ///         them explicitly.
    function unmirrorAntibody(bytes32 keccakId) external;

    // ------------------------------------------------------------------
    //  Reads
    // ------------------------------------------------------------------

    function getAntibody(bytes32 keccakId) external view returns (AntibodyLib.Antibody memory);

    /// @return keccakId Antibody flagging `target`, or `bytes32(0)` if
    ///                  not blocked.
    function isBlocked(address target) external view returns (bytes32 keccakId);

    function getAntibodiesByPublisher(address publisher) external view returns (bytes32[] memory);

    // ------------------------------------------------------------------
    //  Admin
    // ------------------------------------------------------------------

    function setRelayer(address relayer, bool authorized) external;
    function transferAdmin(address newAdmin) external;
}
