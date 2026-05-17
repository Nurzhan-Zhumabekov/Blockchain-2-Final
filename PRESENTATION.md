# PRESENTATION — RWA Tokenization Platform
## Blockchain Technologies 2 — Final Project (Option C)

> Each `---` separator = new slide. Present in any Markdown viewer or paste into Google Slides / PowerPoint.

---

# Slide 1 — Title

# RWA Tokenization Platform
## Blockchain Technologies 2 — Final Project

**Option C: Real-World Asset Tokenization**  
Chain: Arbitrum Sepolia (chain ID 421614)

| # | Name | Role |
|---|------|------|
| 1 | Nurzhan Zhumabekov | Core smart contracts |
| 2 | Abylay Abdykassymov | Governance + V2 upgrade |
| 3 | Abilkhaiyr Sarsenbay | Staking, fork tests, CI/CD, security audit |

---

# Slide 2 — Problem & Solution

## The Problem

Real-world assets (Treasury bonds, real estate, commodities) are:
- Illiquid — hard to trade
- Opaque — no on-chain transparency
- Non-composable — can't be used in DeFi

## Our Solution

Tokenize any real-world asset and plug it into DeFi:

```
Real Asset → ERC-20 Token → Yield Vault + AMM + Staking + DAO
```

Every component is fully on-chain, upgradeable, and governed by a DAO.

---

# Slide 3 — Architecture

## System Architecture

```
RWAFactory (CREATE2)
    │
    ├── RWAToken (UUPS V1) ──── upgrade ──► RWATokenV2 + Proof-of-Reserve
    ├── RWAVault (ERC-4626)
    └── AssetCertificate (Soulbound NFT)

RWAPool (x·y=k AMM, Yul assembly, 0.3% fee)

GovernanceToken (ERC-20Votes + ERC-20Permit)
    │
    ├── RWAGovernor (4% quorum, 1-week voting)
    └── RWATimelock (2-day delay) ◄── holds all admin roles post-deploy

RWAStaking (Synthetix-style proportional rewards)
```

**10 contracts — 1 deployment script — 1 broadcast**

---

# Slide 4 — Smart Contracts

## Contract Highlights

| Contract | Pattern | Highlight |
|----------|---------|-----------|
| GovernanceToken | ERC-20Votes + UUPS | Delegatable votes, ERC-20Permit |
| RWAToken V1 | ERC-20 + UUPS | Chainlink feed staleness 24h |
| RWATokenV2 | UUPS upgrade | **Proof-of-Reserve** — can't mint more than backing |
| RWAVault | ERC-4626 | Manager injects real-world yield → share value rises |
| RWAFactory | CREATE2 | Deterministic addresses, Yul address prediction |
| RWAPool | x·y=k AMM | **Yul assembly** getAmountOut + Babylonian sqrt |
| AssetCertificate | ERC-721 | **Soulbound** — all 4 transfer methods revert |
| RWAGovernor | OZ Governor | 1000 GOV threshold, 1-day delay, 1-week period |
| RWATimelock | TimelockController | 2-day delay, only admin post-deploy |
| RWAStaking | Synthetix | Rewards ∝ stake × time |

---

# Slide 5 — Technical Highlights

## Key Engineering Decisions

### 1. UUPS Proxy Pattern
```solidity
// V1 → V2 upgrade adds Proof-of-Reserve without changing address
proxy.upgradeToAndCall(
    address(rwaTokenV2Impl),
    abi.encodeCall(RWATokenV2.initializeV2, (reserveFeedAddress))
);
```

### 2. Inline Yul Assembly (gas optimization)
```yasm
// getAmountOut — 0.3% fee constant-product AMM
let amountInWithFee := mul(amountIn, 997)
let numerator := mul(amountInWithFee, reserveOut)
let denominator := add(mul(reserveIn, 1000), amountInWithFee)
amountOut := div(numerator, denominator)
```

### 3. Chainlink Proof-of-Reserve (V2)
```solidity
// Scales feed decimals before comparing with 18-decimal token supply
uint256 reserveScaled = feedDecimals >= 18
    ? uint256(reserveBalance) / (10 ** (feedDecimals - 18))
    : uint256(reserveBalance) * (10 ** (18 - feedDecimals));
if (reserveScaled < totalSupply() + amount)
    revert ReserveDeficit(...);
```

---

# Slide 6 — Testing Results

## 142 Tests — 0 Failures

| Test Type | Count | Configuration |
|-----------|-------|--------------|
| Unit tests | 106 | Standard, isolated |
| Fuzz tests | 11 | 256 runs each |
| Invariant tests | 5 | 64 runs × 960 calls each |
| Fork tests | 9 | Arbitrum Sepolia (live Chainlink feeds) |
| **Total** | **142** | **ALL PASS** |

---

# Slide 7 — Screenshot: Unit Tests

## Unit + Fuzz + Invariant Tests — 133/133 PASS

> **[INSERT SCREENSHOT 1 HERE]**
>
> `Ran 10 test suites in 507.78ms: 133 tests passed, 0 failed, 0 skipped`

---

# Slide 8 — Screenshot: Fork Tests

## Fork Tests — 9/9 PASS (Arbitrum Sepolia)

> **[INSERT SCREENSHOT 2 HERE]**
>
> `Ran 1 test suite in 10.05s: 9 tests passed, 0 failed, 0 skipped`
>
> Including: `test_Fork_UpgradeToV2_ProofOfReserve` — live V1→V2 upgrade on-chain

---

# Slide 9 — Invariant Tests

## What Invariants Did We Test?

The fuzzer runs 960 random calls (swaps, deposits, stakes) and checks after every call:

| Invariant | What It Guarantees |
|-----------|-------------------|
| `invariant_ReservesMatchBalances` | AMM reserves always equal actual token balances |
| `invariant_KNeverDecreases` | x·y product never shrinks (fees only add) |
| `invariant_TotalSupplyMatchesShares` | Vault share math is consistent |
| `invariant_StakeNeverExceedsTotal` | No user's stake exceeds the total |
| `invariant_VaultSharesNotDiluted` | Share value never decreases |

**Bug found:** Pool was being used as a fuzz sender → self-swap corrupted reserves.  
**Fix:** `SelfSwapNotAllowed` guard added + `targetSender()` restricts fuzz actors.

---

# Slide 10 — Security Audit

## Security Findings — All Resolved

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| HIGH-01 | High | Reentrancy in RWAPool.swap | ✅ RESOLVED — nonReentrant + SelfSwapNotAllowed |
| HIGH-02 | High | Mint after role revocation | ✅ RESOLVED — mint now before revoke |
| MED-01 | Medium | Stale price not checked in AMM | ✅ RESOLVED — 1h staleness check |
| MED-02 | Medium | Decimal mismatch in V2 PoR | ✅ RESOLVED — scaled to 18 decimals |
| MED-03 | Medium | Soulbound bypassed via safeTransfer | ✅ RESOLVED — all 4 methods overridden |
| LOW-01 | Low | Invariant prank leak | ✅ RESOLVED — stopPrank on all paths |
| LOW-02 | Low | Fork test role assumption | ✅ RESOLVED — issuer is admin, not deployer |
| LOW-03 | Low | No zero-amount guard in addLiquidity | ✅ RESOLVED — ZeroAmount revert added |

Full report: `audit/SECURITY_REPORT.md`

---

# Slide 11 — Screenshot: Gas Report

## Gas Report

> **[INSERT SCREENSHOT 3 HERE]**
>
> `forge test --no-match-contract "ForkTest" --gas-report`

Key functions and their gas costs shown per call (min / avg / max).

---

# Slide 12 — Screenshot: Coverage

## Test Coverage

> **[INSERT SCREENSHOT 4 HERE]**
>
> `forge coverage --no-match-contract "ForkTest" --report summary`

Coverage measured across all `src/` contracts.

---

# Slide 13 — CI/CD Pipeline

## GitHub Actions Pipeline

```
Every Push / Pull Request to main
         │
         ▼
┌─────────────────────────────────────────┐
│  1. forge build    — compile contracts  │
│  2. forge test     — 133 unit/fuzz/inv  │
│  3. forge coverage — line coverage      │
│  4. slither        — static analysis    │
│  5. forge script   — dry-run deploy     │
└─────────────────────────────────────────┘
```

File: `.github/workflows/ci.yml`  
Config: `slither.config.json`

All steps are required — PR cannot merge if any step fails.

---

# Slide 14 — Deployment

## Deployment: One Command

```bash
make deploy-l2-arbitrum
# ↓
forge script script/DeployL2.s.sol:DeployL2 \
    --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
    --broadcast --verify \
    --etherscan-api-key $ARBISCAN_API_KEY \
    --delay 5 -vvvv
```

### Deployment Order (critical)

1. GovernanceToken proxy  
2. RWAFactory (deploys RWAToken + RWAVault implementations)  
3. `onboardAsset()` → RWAToken proxy + RWAVault proxy + NFT certificate  
4. RWAPool (GOV ↔ RWA AMM)  
5. RWAGovernor + RWATimelock  
6. **Mint RWAGOV supply** ← must be BEFORE role revocation  
7. Seed pool with liquidity  
8. Deploy RWAStaking  
9. Grant all admin roles to Timelock  
10. **Revoke deployer roles** — no single EOA controls protocol  

---

# Slide 15 — The Graph + Frontend

## Data Layer: The Graph Subgraph

Indexes all platform events for the frontend:

```graphql
type Swap @entity { id: ID!, amountIn: BigInt!, amountOut: BigInt!, ... }
type Proposal @entity { id: ID!, proposer: Bytes!, description: String!, ... }
type StakeEvent @entity { id: ID!, staker: Bytes!, amount: BigInt!, ... }
# + 5 more entity types
```

## Frontend: React + Wagmi v2 + Viem

- Wallet connection (MetaMask)
- Network detection with banner warning
- Token, Vault, Pool, Staking, Governance panels
- Live data from The Graph

---

# Slide 16 — Requirements Checklist

## All Requirements Met ✅

| Requirement | Result |
|-------------|--------|
| ≥ 50 unit tests | **106 unit tests** |
| ≥ 10 fuzz tests | **11 fuzz tests** (256 runs each) |
| ≥ 5 invariant tests | **5 invariant tests** (960 calls each) |
| ≥ 3 fork tests | **9 fork tests** (live Arbitrum Sepolia) |
| Slither analysis | **Configured + passing** |
| Security audit | **12 findings — all resolved** |
| CI/CD | **GitHub Actions — 5 stages** |
| UUPS upgradeable | **3 contracts** (GovernanceToken, RWAToken, RWAVault) |
| Chainlink feeds | **Staleness + Proof-of-Reserve** |
| ERC-4626 vault | **RWAVault** |
| DAO governance | **RWAGovernor + RWATimelock** |
| Yul assembly | **AMM + sqrt + CREATE2** |
| The Graph | **8 entity types** |
| Frontend | **React + Wagmi v2** |

---

# Slide 17 — Key Bugs We Found & Fixed

## Notable Engineering Challenges

### The Self-Swap Invariant Bug
The Foundry fuzzer used the pool address itself as a transaction sender. The pool calling `swap()` on itself performed a no-op token transfer (balance unchanged) but still updated reserve variables — breaking `invariant_ReservesMatchBalances`. Fixed with a `SelfSwapNotAllowed` guard and `targetSender()` restriction.

### The Decimal Mismatch Bug
Chainlink BTC/USD feed returns `78224_00000000` (8 decimals = $78,224). Token supply is in 18 decimals. Direct comparison always triggered `ReserveDeficit`. Fixed: scale feed answer using `reserveFeed.decimals()` before comparison.

### The Role Assumption Bug
`RWAFactory.onboardAsset(salt, issuer, ...)` makes `issuer` the `DEFAULT_ADMIN_ROLE` holder on the token — not the deployer. Three fork tests assumed the opposite. Fixed: all role-gated calls now use `vm.prank(issuer)`.

---

# Slide 18 — Conclusion

## Summary

- **10 smart contracts** covering token issuance, AMM, yield vault, staking, and DAO governance
- **142 tests** — 106 unit, 11 fuzz, 5 invariant, 9 fork — **all passing**
- **12 security findings** identified and resolved during development
- **Complete CI/CD** pipeline with static analysis
- **The Graph subgraph** + React frontend for full-stack demonstration
- **Chainlink Proof-of-Reserve** enforced at the protocol level (V2 upgrade)

### Final Score

```
142 / 142 tests passed — 0 failed
All security findings resolved
All course requirements exceeded
```

---

*Report: REPORT.md | Audit: audit/SECURITY_REPORT.md | Tests: test/*
