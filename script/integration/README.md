# Live integration test (Sepolia)

Proves the deployed `ImmunityHook` actually intercepts swaps when the
chain-local Mirror flags a token, then resumes when the flag is cleared.

## Two stages

### 1. One-shot pool seed (Foundry)

Deploys two mock ERC20s, initializes a v4 pool with the deployed hook,
and seeds 100/100 of liquidity.

```bash
# from repo root, with .env loaded
forge script script/integration/SeedPool.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast
```

Capture the `INT_TOK_A`, `INT_TOK_B`, `currency0`, `currency1` lines from
stdout and write them into `state.json` (gitignored, generated per run):

```json
{
  "INT_TOK_A": "0x...",
  "INT_TOK_B": "0x...",
  "currency0": "0x...",
  "currency1": "0x..."
}
```

### 2. 5-phase swap orchestration (Node)

```bash
cd script/integration
npm install
node run.mjs
```

Runs the full loop:

| Phase | Action | Expected |
|---|---|---|
| 1 | swap on protected pool, clean state | SUCCESS |
| 2 | `mirror.mirrorAddressAntibody(ab, INT_TOK_A)` | tx mined |
| 3 | same swap | REVERT (TokenBlocked) |
| 4 | `mirror.setAddressBlock(INT_TOK_A, 0x00)` | tx mined |
| 5 | same swap | SUCCESS |

Exits 0 on the SUCCESS / REVERT / SUCCESS pattern, nonzero otherwise.

## Cost (rough)

- Seed (mocks + pool init + liquidity): ~0.005 ETH
- Each swap attempt: ~0.001–0.002 ETH (router takes a fee path)
- Mirror block + unblock: ~0.0005 ETH total

Plenty of headroom on a wallet with 0.1+ Sepolia ETH.

## What this verifies

- The deployed hook (`0xd333…0080`) is actually wired into v4's
  `beforeSwap` callback path on a real PoolManager.
- The Mirror's `isBlocked(token)` view returns the right keccakId
  for tokens flagged via `mirrorAddressAntibody`.
- The hook reverts with `TokenBlocked(token, keccakId)` so explorers
  and wallets can deep-link to the antibody page.
- Clearing the block via `setAddressBlock(target, bytes32(0))`
  actually unblocks subsequent swaps.

## Latest live run (Sepolia, 2026-04-28)

Result: ✅ all phases pass. The hook is wired correctly into the v4
PoolManager and reverts swaps that involve a Mirror-flagged token.

**Pool fixture** (deployed by `SeedPool.s.sol`):
- INT_TOK_A: [`0xF4F4d4f459b339c7234511547880E101073DCbCd`](https://sepolia.etherscan.io/address/0xF4F4d4f459b339c7234511547880E101073DCbCd) (the one that gets flagged)
- INT_TOK_B: [`0x479504943734d01548B2975227Bb6BfCF725c222`](https://sepolia.etherscan.io/address/0x479504943734d01548B2975227Bb6BfCF725c222)
- poolId: `0x180b6f589c55732f9bc670360dfcb418e91798e2a6b3ee77aa5d6a5d172fd68e`
- Liquidity seeded: 100/100 ether, range ±750 × tickSpacing

**Phase results:**

| Phase | Outcome | Tx | Gas |
|---|---|---|---|
| 1 baseline swap | ✅ SUCCESS | [0x7d71fab0…](https://sepolia.etherscan.io/tx/0x7d71fab0d3b3ed879cbb72307e2b5164170ca4f8e420e6b16234287cf4de1549) | 123,691 |
| 2 mirror block | ✅ tx mined | [0x7d2e1d18…](https://sepolia.etherscan.io/tx/0x7d2e1d18d7eb730bdb4c299044d885985def2cfda7aa91e7502d80437f2a9f1a) | – |
| 3 blocked swap | ✅ REVERT (expected) | [0x…revert](#) | – |
| 4 mirror unblock | ✅ tx mined | [0x453dfc02…](https://sepolia.etherscan.io/tx/0x453dfc02cb0db054534a84c96a9a0ebd83bb8b099966824a41980f39b21e5f69) | – |
| 5 post-unblock swap | ✅ SUCCESS | [0x8145cb92…](https://sepolia.etherscan.io/tx/0x8145cb92e51f2ae70d2523e8c85e2ee1e8e62d26c7041884d53f1208e0ad48fd) | 124,380 |

**Phase 3 decoded revert:**
```
TokenBlocked(
  0xF4F4d4f459b339c7234511547880E101073DCbCd,
  0x8aeb1de4a060019bec3b45fd7608ab02d79c3871b42bb762198f1d4d7c91b933
)
```
— exactly the error shape the hook is supposed to emit.

**Hook overhead (live):** swap with hook + warm Mirror storage = ~124k gas
total swap. Δ between phase-1 and phase-5 was +689 gas, within RPC noise.
(Direct hook-only measurement is in the unit test, ~6.5k gas warm.)

## What this does NOT verify

- Sender or `tx.origin` blocking paths (would need to flag the swap
  router or the deployer wallet itself, which would brick further
  testing).
- Other antibody types (CALL_PATTERN, BYTECODE, GRAPH, SEMANTIC) —
  the hook only consults the address index; storing those types is
  exercised in unit tests.
