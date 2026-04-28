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

## What this does NOT verify

- Sender or `tx.origin` blocking paths (would need to flag the swap
  router or the deployer wallet itself, which would brick further
  testing).
- Other antibody types (CALL_PATTERN, BYTECODE, GRAPH, SEMANTIC) —
  the hook only consults the address index; storing those types is
  exercised in unit tests.
