#!/usr/bin/env bash
# One-command live integration test for ImmunityHook on Sepolia.
#
# Usage:
#   ./script/integration/run.sh           — seed a fresh pool + run swap test
#   ./script/integration/run.sh test      — run swap test against existing state.json
#   ./script/integration/run.sh seed      — only seed, don't run swaps
#
# Requires: forge, node, npm, a funded $DEPLOYER_PRIVATE_KEY, $SEPOLIA_RPC_URL.
# Reads .env from repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found at $REPO_ROOT/.env" >&2
  echo "Copy .env.example to .env and fill in deployer key + RPC URL." >&2
  exit 1
fi

# shellcheck source=/dev/null
set -a; . ./.env; set +a

: "${SEPOLIA_RPC_URL:?SEPOLIA_RPC_URL must be set in .env}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY must be set in .env}"

# Defaults — match the deployed addresses in network.json. Override via
# .env if you redeploy.
export HOOK_ADDRESS="${HOOK_ADDRESS:-0xd3335F3d69e97C314350EDA63fB5Ba0163Dd0080}"
export POOL_MANAGER="${POOL_MANAGER:-0xE03A1074c86CFeDd5C142C4F04F1a1536e203543}"
export MIRROR_ADDRESS="${MIRROR_ADDRESS:-0x1be1Ec2F7E2230f9bB1Aa3d5589bB58F8DfD52c7}"

phase="${1:-all}"

if [[ "$phase" == "seed" || "$phase" == "all" ]]; then
  echo "==> Seeding integration pool on Sepolia..."
  echo "    hook=$HOOK_ADDRESS"
  echo "    poolManager=$POOL_MANAGER"
  forge script script/integration/SeedPool.s.sol \
    --rpc-url "$SEPOLIA_RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --broadcast --slow

  if [[ ! -s script/integration/state.json ]]; then
    echo "ERROR: SeedPool did not write state.json" >&2
    exit 1
  fi
  echo "==> Wrote $(realpath script/integration/state.json)"
fi

if [[ "$phase" == "test" || "$phase" == "all" ]]; then
  if [[ ! -s script/integration/state.json ]]; then
    echo "ERROR: state.json missing — run with 'seed' first or 'all'" >&2
    exit 1
  fi

  if [[ ! -d script/integration/node_modules ]]; then
    echo "==> Installing JS deps..."
    (cd script/integration && npm install --silent)
  fi

  echo "==> Running 5-phase swap test..."
  node script/integration/run.mjs
fi
