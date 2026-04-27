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
    function mirrorAntibody(AntibodyLib.Antibody calldata a, bytes32 /*auxiliaryKey*/) external onlyRelayer {
        bytes32 keccakId = AntibodyLib.computeKeccakId(a);
        _antibodies[keccakId] = a;
        emit AntibodyMirrored(keccakId, a.publisher, a.abType);
    }

    function mirrorAddressAntibody(AntibodyLib.Antibody calldata, address) external onlyRelayer {
        revert("not implemented");
    }

    function setAddressBlock(address, bytes32) external onlyRelayer {
        revert("not implemented");
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

    function isBlocked(address) external pure returns (bytes32) {
        revert("not implemented");
    }

    function getAntibodiesByPublisher(address) external pure returns (bytes32[] memory) {
        revert("not implemented");
    }
}
