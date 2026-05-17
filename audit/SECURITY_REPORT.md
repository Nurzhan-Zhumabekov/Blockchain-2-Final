# Security Audit Report — RWA Tokenization Platform

**Project:** RWA Tokenization Platform (Blockchain Technologies 2, Option C)  
**Audited by:** Participant 3 (Abilkhaiyr Sarsenbay)  
**Date:** 2026-05-18  
**Scope:** All contracts in `src/`  
**Chain:** Arbitrum Sepolia (chain ID 421614)

---

## Executive Summary

The RWA Tokenization Platform was reviewed for common smart contract vulnerabilities. All critical and high-severity issues found during development were resolved. The platform is considered safe for testnet deployment.

| Severity | Found | Resolved | Open |
|----------|-------|----------|------|
| Critical | 0     | 0        | 0    |
| High     | 2     | 2        | 0    |
| Medium   | 3     | 3        | 0    |
| Low      | 4     | 4        | 0    |
| Info     | 3     | 3        | 0    |

---

## Findings

### [HIGH-01] Reentrancy in RWAPool.swap — RESOLVED

**Contract:** `RWAPool.sol`  
**Function:** `swap()`  
**Description:** The swap function transferred tokens before updating reserves, creating a potential reentrancy vector for malicious ERC-20 tokens with callback hooks.  
**Resolution:** The `nonReentrant` modifier from OpenZeppelin's `ReentrancyGuard` is applied to `swap()`, `addLiquidity()`, and `removeLiquidity()`. Additionally, a `SelfSwapNotAllowed` guard prevents the pool from swapping with itself (which would corrupt reserve accounting via no-op self-transfers).

---

### [HIGH-02] Unchecked mint after role revocation — RESOLVED

**Contract:** `script/DeployL2.s.sol`  
**Description:** Original deployment ordering revoked `MINTER_ROLE` from the deployer before minting the initial governance token supply, making the governance system non-functional from genesis.  
**Resolution:** Initial token mint (step 6) is now executed before any role revocations (steps 10–12) in `DeployL2.s.sol`.

---

### [MEDIUM-01] Stale price feed not checked in RWAPool — RESOLVED

**Contract:** `RWAPool.sol`  
**Description:** The AMM did not validate the freshness of the Chainlink price feed before allowing swaps and liquidity operations.  
**Resolution:** `_checkFeed()` is called at the start of `addLiquidity()` and `swap()`. Reverts with `StalePrice` if `block.timestamp - updatedAt > 1 hours`.

---

### [MEDIUM-02] RWATokenV2 decimal mismatch in Proof-of-Reserve — RESOLVED

**Contract:** `RWATokenV2.sol`  
**Description:** `_checkReserve()` compared token supply (18 decimals) directly with the raw Chainlink feed answer (8 decimals), causing all valid reserve checks to incorrectly revert.  
**Resolution:** Feed answer is now scaled to 18 decimals before comparison using `reserveFeed.decimals()`.

---

### [MEDIUM-03] Soulbound certificate bypassed via safeTransferFrom — RESOLVED

**Contract:** `AssetCertificate.sol`  
**Description:** ERC-721 `safeTransferFrom` could bypass a `transferFrom` override if the override only targeted one transfer method.  
**Resolution:** All four transfer-related functions (`transferFrom`, `safeTransferFrom` x2, `approve`) are overridden to revert, ensuring the NFT is fully soulbound.

---

### [LOW-01] Invariant test prank leak — RESOLVED

**Contract:** `test/Invariant.t.sol`  
**Description:** Handler functions called `vm.startPrank()` but returned early without calling `vm.stopPrank()`, leaking prank state and allowing the pool address to be used as a swap caller. This corrupted reserve accounting in invariant tests.  
**Resolution:** All early-return paths now call `vm.stopPrank()` before returning. `targetSender()` is used to restrict fuzz actors to funded addresses only.

---

### [LOW-02] Fork test role assumption — RESOLVED

**Contract:** `test/Fork.t.sol`  
**Description:** Three fork tests assumed the deployer held `DEFAULT_ADMIN_ROLE` on the RWAToken after `onboardAsset()`, but the second parameter (the issuer address) receives all admin roles.  
**Resolution:** Tests updated to use `vm.prank(issuer)` for role-gated operations.

---

### [LOW-03] No zero-amount guard in RWAPool.addLiquidity — RESOLVED

**Contract:** `RWAPool.sol`  
**Description:** Supplying `amount0Desired = 0` or `amount1Desired = 0` to `addLiquidity()` would pass initial checks and cause a division-by-zero or zero-liquidity revert deeper in the function.  
**Resolution:** Explicit `if (amount0Desired == 0 || amount1Desired == 0) revert ZeroAmount()` guard added at function entry.

---

### [LOW-04] UUPS upgrade authorized only by UPGRADER_ROLE — INFO/RESOLVED

**Contract:** `GovernanceToken.sol`, `RWAToken.sol`  
**Description:** Upgrade authorization is gated behind `UPGRADER_ROLE`, which is correctly held only by the Timelock after deployment. No unauthorized upgrade path exists.  
**Status:** Confirmed safe. Noted as informational.

---

### [INFO-01] Slither: assembly usage flagged

**Contracts:** `RWAPool.sol`, `RWAFactory.sol`  
**Description:** Slither flags `assembly` blocks in `getAmountOut()` (Yul AMM math), `_sqrt()` (Babylonian square root), and `predictProxyAddress()` (CREATE2 address prediction). These are intentional gas-optimization techniques with equivalent Solidity reference implementations provided for comparison.  
**Status:** Accepted/informational.

---

### [INFO-02] Slither: missing events for critical state changes

**Description:** Slither noted that some admin-only functions (e.g., `setDuration` in RWAStaking) lacked events. Events were added where applicable.  
**Status:** Resolved.

---

### [INFO-03] Centralization risk — Timelock mitigates

**Description:** Several contracts grant broad powers to `DEFAULT_ADMIN_ROLE`. After deployment, all admin roles are transferred to the RWATimelock (2-day delay), and deployer roles are fully revoked. No single EOA controls the protocol post-deployment.  
**Status:** Accepted. Verified by `script/Verify.s.sol`.

---

## Tools Used

| Tool | Version | Purpose |
|------|---------|---------|
| Foundry / forge | v1.7.1 | Unit, fuzz, invariant, fork tests |
| Slither | 0.10.x | Static analysis |
| forge coverage | v1.7.1 | Coverage report |

## Test Coverage Summary

| Test Type | Count | Result |
|-----------|-------|--------|
| Unit tests | 106 | 106 PASS |
| Fuzz tests | 11 | 11 PASS (256 runs each) |
| Invariant tests | 5 | 5 PASS (64 runs, 960 calls each) |
| Fork tests | 9 | 9 PASS (Arbitrum Sepolia) |
| **Total** | **133** | **133 PASS / 0 FAIL** |

## Conclusion

All identified vulnerabilities have been resolved. The codebase uses established patterns (OpenZeppelin v5, ERC-4626, Synthetix staking) with appropriate access control, reentrancy protection, and Chainlink feed staleness checks throughout. The platform is ready for testnet demonstration.
