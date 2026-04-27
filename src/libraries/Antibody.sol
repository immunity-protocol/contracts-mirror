// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title AntibodyLib
/// @notice Type contract between the 0G Registry and per-chain Mirrors.
/// @dev Struct field order, types, and packing MUST match
///      `immunity-contracts-0g/contracts/interfaces/IRegistry.sol`. Drift
///      breaks the relayer's calldata encoder.
library AntibodyLib {
    /// @notice Top-level antibody classification.
    enum AntibodyType {
        ADDRESS,        // 0 — blacklisted wallet
        CALL_PATTERN,   // 1 — function selector + args fingerprint
        BYTECODE,       // 2 — runtime bytecode hash for clone detection
        GRAPH,          // 3 — taint topology
        SEMANTIC        // 4 — manipulation embedding / structural markers / poisoned content
    }

    /// @notice Determination produced by the reviewer TEE.
    enum Verdict {
        MALICIOUS,      // 0
        SUSPICIOUS      // 1
    }

    /// @notice Antibody lifecycle status.
    enum Status {
        ACTIVE,         // 0
        CHALLENGED,     // 1 — under v2 challenge game (unused in v1)
        SLASHED,        // 2 — admin slashed; stake forfeited to treasury
        EXPIRED         // 3 — past publisher-chosen expiration
    }

    /// @notice Stored antibody envelope. Off-chain consumers hydrate richer
    ///         data from 0G Storage via `evidenceCid` / `contextHash`.
    /// @dev Field ordering targets ~7 storage slots via packing — must
    ///      match the Registry's struct exactly.
    struct Antibody {
        bytes32 primaryMatcherHash;     // slot 0
        bytes32 evidenceCid;            // slot 1
        bytes32 contextHash;            // slot 2
        bytes32 embeddingHash;          // slot 3 — SEMANTIC only
        bytes32 attestation;            // slot 4 — TEE quote hash
        address publisher;              // slot 5 (packed with stakeLockUntil + immSeq)
        uint64  stakeLockUntil;
        uint32  immSeq;
        address reviewer;               // slot 6 (packed with expiresAt + abType + flavor + verdict + confidence)
        uint64  expiresAt;
        uint8   abType;
        uint8   flavor;
        uint8   verdict;
        uint8   confidence;
        uint64  createdAt;              // slot 7 (packed with stakeAmount + severity + status + isSeeded)
        uint96  stakeAmount;
        uint8   severity;
        uint8   status;
        uint8   isSeeded;
    }

    /// @notice Canonical content-addressed antibody identifier.
    /// @dev Same derivation as `Registry._hash`. Lets the Mirror compute
    ///      the keccakId itself rather than trust the relayer.
    function computeKeccakId(Antibody memory a) internal pure returns (bytes32) {
        return keccak256(abi.encode(a.abType, a.flavor, a.primaryMatcherHash, a.publisher));
    }
}
