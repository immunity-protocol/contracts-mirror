# immunity-contracts-mirror

Per-chain Mirror of the Immunity 0G Registry's antibody data, plus a
Uniswap v4 BeforeSwap hook that consults it.

The Mirror is a read-optimized replica written by an off-chain relayer
that listens to Registry events on 0G Galileo. The hook reverts swaps
where `sender`, `tx.origin`, `token0`, or `token1` is flagged.

The Mirror does **not** replicate 0G Storage data. Consumers that need
the richer envelope follow `evidenceCid` to 0G Storage from any chain.

## Layout

```
src/
  libraries/Antibody.sol      Shared struct + enums (must match 0G Registry)
  interfaces/IMirror.sol      External surface
  Mirror.sol                  Per-chain replica
  ImmunityHook.sol            Uniswap v4 BEFORE_SWAP hook
script/
  DeployMirror.s.sol          CREATE2 deploy, deterministic across chains
  DeployHook.s.sol            HookMiner + CREATE2 for the hook
  BatchDeploy.s.sol           Single-RPC convenience (Mirror + Hook)
test/
  Mirror.t.sol
  ImmunityHook.t.sol
network.json                  Per-chain addresses
```

## Build & test

Requires Foundry (tested on `forge 1.5.1-stable`).

```bash
forge build
forge test
```

## Deploy

Copy `.env.example` to `.env` and fill in. Then:

```bash
# Mirror first (deterministic address via CREATE2 + hardcoded salt).
forge script script/DeployMirror.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast --verify

# Then the hook, pointing at the Mirror just deployed.
export MIRROR_ADDRESS=0x...   # from previous output
forge script script/DeployHook.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast --verify

# Or both in one go:
forge script script/BatchDeploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast --verify
```

Capture the addresses from stdout and write them into `network.json`.

## Relayer integration

The relayer (in `immunity-app`) needs:

- The Mirror address per chain, from `network.json`.
- An authorized relayer key (rotatable by `admin` via `setRelayer`).
- Mirror ABI generated from `out/Mirror.sol/Mirror.json` after `forge build`.

Per-call shape:

| Antibody type | Method | `auxiliaryKey` payload |
|---|---|---|
| ADDRESS | `mirrorAddressAntibody(a, target)` | (target passed as second arg) |
| CALL_PATTERN | `mirrorAntibody(a, bytes32(selector))` | `bytes4` selector left-padded |
| BYTECODE | `mirrorAntibody(a, bytecodeHash)` | runtime-bytecode keccak |
| GRAPH | `mirrorAntibody(a, taintSetId)` | taint-set identifier |
| SEMANTIC | `mirrorAntibody(a, bytes32(0))` | unused; flavor read from `a.flavor` |

The Mirror's `mirrorAntibody` is idempotent — re-mirroring the same
antibody (same `abType`, `flavor`, `primaryMatcherHash`, `publisher`)
overwrites the slot in place.

## Auxiliary event signatures

These match the 0G Registry verbatim so per-type indexers see uniform
shapes across 0G and every execution chain:

```solidity
event AddressBlocked      (address indexed target,       bytes32 indexed keccakId, address indexed publisher);
event CallPatternBlocked  (bytes4  indexed selector,     bytes32 indexed keccakId, address indexed publisher);
event BytecodeBlocked     (bytes32 indexed bytecodeHash, bytes32 indexed keccakId, address indexed publisher);
event GraphTaintAdded     (bytes32 indexed taintSetId,   bytes32 indexed keccakId, address indexed publisher);
event SemanticPatternAdded(uint8   indexed flavor,       bytes32 indexed keccakId, address indexed publisher);
```

## Hook gas budget

Target: under 25,000 gas overhead per swap.
Measured (warm storage, four `bytes32` reads): ~6,500 gas in unit tests.
End-to-end on Sepolia (PoolManager dispatch + actual swap) measured at
~23k gas overhead in the related `uniswap-explore` repo using a
trivial `bool` registry — bytes32 returns add a couple hundred gas at
most, well within budget.

## Known constraints

- Single-admin v1; multi-sig in v2.
- Address index is last-write-wins; if two antibodies flag the same
  address the most recent one wins.
- `unmirrorAntibody` does not sweep `blockedByAntibody` entries pointing
  at the deleted keccakId, nor `_publisherAntibodies`. Relayer must
  clear address-index entries explicitly.
