// Live 5-phase integration test for ImmunityHook on Sepolia.
//
//   Phase 1: clean swap on protected pool                  → expect SUCCESS
//   Phase 2: mirror.mirrorAddressAntibody(envelope, INT_A) → mark INT_A blocked
//   Phase 3: same swap                                     → expect REVERT (TokenBlocked)
//   Phase 4: mirror.setAddressBlock(INT_A, 0x00..)         → clear the block
//   Phase 5: same swap                                     → expect SUCCESS
//
// Reads pool addresses from state.json (written by SeedPool.s.sol via the
// caller's redirect of stdout, or pasted manually).

import "dotenv/config";
import { ethers } from "ethers";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ---------- env / state ----------
const RPC = process.env.SEPOLIA_RPC_URL;
const PK  = process.env.DEPLOYER_PRIVATE_KEY;
const MIRROR = process.env.MIRROR_ADDRESS ?? "0x1be1Ec2F7E2230f9bB1Aa3d5589bB58F8DfD52c7";
const HOOK = process.env.HOOK_ADDRESS ?? "0xd3335F3d69e97C314350EDA63fB5Ba0163Dd0080";
if (!RPC || !PK) throw new Error("missing SEPOLIA_RPC_URL or DEPLOYER_PRIVATE_KEY");

const state = JSON.parse(readFileSync(join(__dirname, "state.json"), "utf8"));
const { currency0, currency1, INT_TOK_A } = state;
if (!currency0 || !currency1 || !INT_TOK_A) {
  throw new Error("state.json must contain currency0, currency1, INT_TOK_A");
}

// hookmate's V4SwapRouter, canonical Sepolia address (also works on mainnet)
const V4_SWAP_ROUTER = "0xf13D190e9117920c703d79B5F33732e10049b115";

// ---------- ABIs ----------
const ERC20 = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
];

const ANTIBODY_TUPLE =
  "tuple(bytes32 primaryMatcherHash,bytes32 evidenceCid,bytes32 contextHash,bytes32 embeddingHash,bytes32 attestation,address publisher,uint64 stakeLockUntil,uint32 immSeq,address reviewer,uint64 expiresAt,uint8 abType,uint8 flavor,uint8 verdict,uint8 confidence,uint64 createdAt,uint96 stakeAmount,uint8 severity,uint8 status,uint8 isSeeded)";

const MIRROR_ABI = [
  `function mirrorAddressAntibody(${ANTIBODY_TUPLE} a, address target)`,
  "function setAddressBlock(address target, bytes32 keccakId)",
  "function isBlocked(address) view returns (bytes32)",
];

// Hook custom errors — used to decode reverts that bubble up through the
// router. ethers won't auto-decode because the call goes through the
// PoolManager → hook chain, not directly to the hook.
const HOOK_ERRORS = new ethers.Interface([
  "error TokenBlocked(address token, bytes32 keccakId)",
  "error SenderBlocked(address sender, bytes32 keccakId)",
  "error OriginBlocked(address origin, bytes32 keccakId)",
]);

function decodeHookRevert(err) {
  const data = err.data ?? err.error?.data ?? err.info?.error?.data;
  if (!data || data === "0x") return null;
  // The PoolManager wraps hook reverts inside `Wrap(WrappedError(...))`. Try
  // decoding the raw data first; if that fails, try stripping nested
  // wrappers.
  for (const candidate of unwrapCandidates(data)) {
    try {
      const parsed = HOOK_ERRORS.parseError(candidate);
      return `${parsed.name}(${parsed.args.map((a) => a.toString()).join(", ")})`;
    } catch {}
  }
  return null;
}

function unwrapCandidates(hex) {
  const out = [hex];
  // Heuristic: scan for a 4-byte selector that matches one of our known
  // errors anywhere in the payload. Cheap and reliable for nested wraps.
  const selectors = HOOK_ERRORS.fragments
    .filter((f) => f.type === "error")
    .map((f) => HOOK_ERRORS.getError(f.name).selector);
  const buf = hex.startsWith("0x") ? hex.slice(2) : hex;
  for (const sel of selectors) {
    const idx = buf.indexOf(sel.slice(2).toLowerCase());
    if (idx > 0) out.push("0x" + buf.slice(idx));
  }
  return out;
}

const ROUTER_ABI = [
  {
    type: "function",
    name: "swapExactTokensForTokens",
    stateMutability: "payable",
    inputs: [
      { name: "amountIn", type: "uint256" },
      { name: "amountOutMin", type: "uint256" },
      { name: "zeroForOne", type: "bool" },
      {
        name: "poolKey",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
      { name: "hookData", type: "bytes" },
      { name: "receiver", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [{ name: "delta", type: "int256" }],
  },
];

// ---------- setup ----------
const provider = new ethers.JsonRpcProvider(RPC);
const wallet = new ethers.Wallet(PK, provider);
console.log(`signer:        ${wallet.address}`);
console.log(`Mirror:        ${MIRROR}`);
console.log(`Hook:          ${HOOK}`);
console.log(`currency0:     ${currency0}`);
console.log(`currency1:     ${currency1}`);
console.log(`token to flag: ${INT_TOK_A}`);

const router = new ethers.Contract(V4_SWAP_ROUTER, ROUTER_ABI, wallet);
const mirror = new ethers.Contract(MIRROR, MIRROR_ABI, wallet);

const poolKey = {
  currency0,
  currency1,
  fee: 3000,
  tickSpacing: 60,
  hooks: HOOK,
};

// zeroForOne direction. The token to flag (INT_TOK_A) may be currency0 or
// currency1. The hook checks BOTH, so direction doesn't matter for blocking,
// but we pick the side whose `from` token we have allowance for.
const zeroForOne = currency0.toLowerCase() === INT_TOK_A.toLowerCase()
  ? true   // selling currency0 (= INT_TOK_A) for currency1
  : false; // selling currency1 (= INT_TOK_A) for currency0

const fromToken = zeroForOne ? currency0 : currency1;

// ---------- helpers ----------
async function ensureRouterApproval() {
  const t = new ethers.Contract(fromToken, ERC20, wallet);
  const allowance = await t.allowance(wallet.address, V4_SWAP_ROUTER);
  if (allowance < ethers.parseUnits("1", 30)) {
    console.log(`approving ${fromToken.slice(0, 10)}… → V4SwapRouter`);
    await (await t.approve(V4_SWAP_ROUTER, ethers.MaxUint256)).wait();
  }
}

async function doSwap(label) {
  const deadline = Math.floor(Date.now() / 1000) + 600;
  const t0 = Date.now();
  try {
    const tx = await router.swapExactTokensForTokens(
      ethers.parseEther("0.01"),
      0n,
      zeroForOne,
      poolKey,
      "0x",
      wallet.address,
      deadline,
    );
    const rcpt = await tx.wait();
    const ms = Date.now() - t0;
    console.log(`  ✅ ${label}: tx ${tx.hash} gas ${rcpt.gasUsed} (${ms}ms)`);
    return { ok: true, txHash: tx.hash, gasUsed: rcpt.gasUsed, ms };
  } catch (err) {
    const ms = Date.now() - t0;
    const decoded = decodeHookRevert(err);
    const reason = decoded ?? err.reason ?? err.shortMessage ?? err.message?.split("\n")[0] ?? "unknown";
    console.log(`  ❌ ${label}: REVERT after ${ms}ms — ${reason}`);
    return { ok: false, reason, decoded, ms };
  }
}

function buildAntibody() {
  const matcher = ethers.id(`integration.test.${Date.now()}`);
  return {
    primaryMatcherHash: matcher,
    evidenceCid: ethers.ZeroHash,
    contextHash: ethers.ZeroHash,
    embeddingHash: ethers.ZeroHash,
    attestation: ethers.ZeroHash,
    publisher: wallet.address,
    stakeLockUntil: 0n,
    immSeq: 0,
    reviewer: ethers.ZeroAddress,
    expiresAt: 0n,
    abType: 0,        // ADDRESS
    flavor: 0,
    verdict: 0,       // MALICIOUS
    confidence: 90,
    createdAt: BigInt(Math.floor(Date.now() / 1000)),
    stakeAmount: 0n,
    severity: 80,
    status: 0,        // ACTIVE
    isSeeded: 1,
  };
}

// ---------- main ----------
async function main() {
  await ensureRouterApproval();
  // Approve the OTHER side too so a second-leg swap (post-unblock) works
  // either way the user might want to re-run.
  const counter = zeroForOne ? currency1 : currency0;
  const ct = new ethers.Contract(counter, ERC20, wallet);
  if ((await ct.allowance(wallet.address, V4_SWAP_ROUTER)) < ethers.parseUnits("1", 30)) {
    await (await ct.approve(V4_SWAP_ROUTER, ethers.MaxUint256)).wait();
  }

  console.log("\n=== Phase 1: clean swap ===");
  const r1 = await doSwap("baseline                  ");

  console.log("\n=== Phase 2: mirror antibody flagging INT_TOK_A ===");
  const ab = buildAntibody();
  const blockTx = await mirror.mirrorAddressAntibody(ab, INT_TOK_A);
  await blockTx.wait();
  const id = await mirror.isBlocked(INT_TOK_A);
  console.log(`  blocked via tx ${blockTx.hash}; isBlocked = ${id}`);
  if (id === ethers.ZeroHash) throw new Error("Mirror did not record block");

  console.log("\n=== Phase 3: swap should revert ===");
  const r3 = await doSwap("blocked                   ");

  console.log("\n=== Phase 4: clear block via setAddressBlock(INT_TOK_A, 0) ===");
  const unblockTx = await mirror.setAddressBlock(INT_TOK_A, ethers.ZeroHash);
  await unblockTx.wait();
  console.log(`  unblocked via tx ${unblockTx.hash}`);

  console.log("\n=== Phase 5: swap should resume ===");
  const r5 = await doSwap("post-unblock              ");

  console.log("\n=== Summary ===");
  console.log(`  1. baseline:              ${r1.ok ? "PASS" : "FAIL"}${r1.gasUsed ? ` gas=${r1.gasUsed}` : ""}`);
  console.log(`  3. blocked (expect FAIL): ${!r3.ok ? "PASS (reverted)" : "FAIL (should have reverted)"}`);
  console.log(`  5. post-unblock:          ${r5.ok ? "PASS" : "FAIL"}${r5.gasUsed ? ` gas=${r5.gasUsed}` : ""}`);

  if (r1.gasUsed && r5.gasUsed && r3.reason) {
    const diff = Number(r5.gasUsed - r1.gasUsed);
    console.log(`\n  baseline vs post-unblock gas Δ: ${diff > 0 ? "+" : ""}${diff} gas`);
    console.log(`  phase-3 revert reason: ${r3.reason}`);
  }

  const ok = r1.ok && !r3.ok && r5.ok;
  // Stronger assertion: phase-3 must be the TokenBlocked error specifically,
  // not some other revert. If we couldn't decode, fail loudly.
  const r3IsTokenBlocked = r3.decoded?.startsWith("TokenBlocked(");
  if (!ok || !r3IsTokenBlocked) {
    console.error("\nFAIL — pattern did not match SUCCESS / TokenBlocked-REVERT / SUCCESS");
    if (r3.ok) console.error("  phase 3 succeeded but should have reverted");
    if (!r3IsTokenBlocked) console.error(`  phase 3 reverted but not with TokenBlocked: ${r3.decoded ?? r3.reason}`);
    process.exit(2);
  }
  console.log("\nOK — hook intercepts swaps as designed");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
