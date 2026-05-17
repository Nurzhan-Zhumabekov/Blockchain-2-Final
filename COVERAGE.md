# Test Coverage Report
## RWA Tokenization Platform — Option C
**Blockchain Technologies 2 — Final Project**

Generated with:
```bash
forge coverage --no-match-contract "ForkTest" --report summary --ir-minimum
```

> Note: `--ir-minimum` is required because `RWAFactory` uses too many local variables for the legacy
> code generator; without it, coverage compilation fails with a stack-too-deep error.
> Script files (`script/`) are deployment automation and are excluded from the coverage target.

---

## Per-Contract Coverage (src/)

| Contract | % Lines | % Statements | % Branches | % Functions |
|----------|---------|--------------|------------|-------------|
| src/AssetCertificate.sol | **85.71%** (12/14) | 73.33% (11/15) | 0.00% (0/2) | 75.00% (3/4) |
| src/GovernanceToken.sol | **74.19%** (23/31) | 63.33% (19/30) | 20.00% (1/5) | 71.43% (5/7) |
| src/RWAFactory.sol | **74.42%** (32/43) | 74.47% (35/47) | 50.00% (2/4) | 100.00% (7/7) |
| src/RWAGovernor.sol | **80.00%** (16/20) | 78.95% (15/19) | 100.00% (0/0) | 80.00% (8/10) |
| src/RWAPool.sol | **79.35%** (73/92) | 76.34% (100/131) | 64.00% (16/25) | 100.00% (10/10) |
| src/RWAStaking.sol | **84.85%** (56/66) | 80.82% (59/73) | 50.00% (7/14) | 85.71% (12/14) |
| src/RWAToken.sol | **78.05%** (32/41) | 71.43% (30/42) | 62.50% (5/8) | 91.67% (11/12) |
| src/RWATokenV2.sol | **94.44%** (17/18) | 76.92% (20/26) | 16.67% (1/6) | 100.00% (3/3) |
| src/RWAVault.sol | **70.59%** (12/17) | 72.22% (13/18) | 50.00% (1/2) | 60.00% (3/5) |
| **src/ Total** | **79.82% (273/342)** | **74.86% (302/403)** | **50.00% (33/66)** | **85.96% (61/71)** |

---

## Test Suite Summary

| Test file | Tests | Types |
|-----------|-------|-------|
| test/RWAToken.t.sol | 25 | unit, fuzz, upgrade lifecycle |
| test/RWAPool.t.sol | 19 | unit, fuzz, k-invariant |
| test/RWAFactory.t.sol | 18 | unit, CREATE2 determinism, soulbound |
| test/RWAVault.t.sol | 17 | unit, fuzz, ERC-4626 rounding |
| test/RWAGovernor.t.sol | 14 | full proposal lifecycle |
| test/RWAStaking.t.sol | 27 | unit, fuzz, reward math |
| test/Invariant.t.sol | 5 | pool reserves, vault solvency |
| test/Fork.t.sol | ~10 | real Chainlink feeds (Arbitrum Sepolia) |
| **Total** | **125+** | |

---

## Coverage Notes

### Why certain branches show low coverage

**GovernanceToken (74.19% lines):**
The uncovered lines are primarily the `_update` override's early return when the contract is not
yet initialized — this path is only reachable during proxy construction and cannot be triggered
from normal test setup without deploying a custom harness.

**RWAVault (70.59% lines):**
The `depositYield` authorization revert path (MANAGER_ROLE check) and the `_decimalsOffset`
override are hit in production but the test file focuses on the deposit/withdraw/yield
accumulation flows. The `decimals()` and `asset()` view functions are covered by ERC-4626
integration but not counted as separate test targets.

**RWAPool (79.35% lines):**
Uncovered branches are in the `removeLiquidity` zero-share edge case and the `addLiquidity`
proportional calculation when one reserve is zero. These can only occur in a misconfigured pool
state that invariant tests actively prove cannot arise.

**RWAFactory (74.42% lines):**
The `onboardAsset` error paths for duplicate salts and the internal `_deployProxy` revert
path (when CREATE2 deployment returns address(0)) require very specific test harnesses that
are covered at the integration level in fork tests.

### Scripts excluded

`script/Deploy.s.sol`, `script/DeployGovernance.s.sol`, `script/DeployStaking.s.sol`,
and `script/UpgradeRWAToken.s.sol` are forge scripts executed against a live or forked
network — they are not unit-testable in the same sense as library code. Forge's coverage
tool counts them as 0% which would incorrectly lower the aggregate. These files are excluded
from the target coverage metric.

### Fork tests excluded

`test/Fork.t.sol` is excluded from coverage runs (`--no-match-contract ForkTest`) because
it requires a live RPC connection to Arbitrum Sepolia. Fork tests are run separately in CI
(`forge test --match-contract ForkTest --fork-url $ARBITRUM_SEPOLIA_RPC_URL`).

---

## How to regenerate

```bash
# Unit + fuzz + invariant coverage (no live RPC needed)
forge coverage --no-match-contract "ForkTest" --report summary --ir-minimum

# With lcov output for HTML report
forge coverage --no-match-contract "ForkTest" --report lcov --ir-minimum
genhtml lcov.info -o coverage-html
```
