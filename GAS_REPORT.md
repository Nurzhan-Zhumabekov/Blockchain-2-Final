# Gas Optimization Report
## RWA Tokenization Platform — Option C
**Blockchain Technologies 2 — Final Project**

---

## 1. Overview

This report documents the gas optimization techniques applied across the RWA Tokenization Platform and benchmarks Yul assembly implementations against their Solidity equivalents.

All measurements were taken with:
- `optimizer = true`, `optimizer_runs = 200`
- `via_ir = true` (IR-based code generation, required to avoid stack-too-deep in RWAFactory)
- EVM version: `cancun`
- Foundry version: nightly

---

## 2. Yul vs Solidity Benchmarks

Three functions were implemented in both Yul assembly and pure Solidity for direct comparison.

### 2.1 `getAmountOut` — AMM Swap Calculation

**Location:** `src/RWAPool.sol`

This function is called on every swap. It computes the constant-product AMM output:

```
amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
```

**Yul implementation:**
```solidity
function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
    public pure returns (uint256 amountOut)
{
    if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
    assembly ("memory-safe") {
        let amountInWithFee := mul(amountIn, 997)
        let numerator       := mul(amountInWithFee, reserveOut)
        let denominator     := add(mul(reserveIn, 1000), amountInWithFee)
        amountOut           := div(numerator, denominator)
    }
}
```

**Solidity equivalent:**
```solidity
function getAmountOutSolidity(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
    public pure returns (uint256)
{
    if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
    uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - FEE_NUMERATOR);
    return (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
}
```

**Results:**

| Implementation | Gas (isolated call) | Savings |
|----------------|-------------------|---------|
| Solidity | ~450 gas | baseline |
| Yul | ~260 gas | ~42% |

The Yul version avoids:
- Loading `FEE_DENOMINATOR` and `FEE_NUMERATOR` from storage/code (they're constants, but the Solidity compiler still generates PUSH opcodes)
- Intermediate variable stack management
- Overflow checks (removed since Yul operates unchecked)

**Test:** `test_GetAmountOut_MatchesSolidity` and `testFuzz_GetAmountOut_MatchesSolidity` confirm identical outputs across 256 fuzz runs.

---

### 2.2 `predictProxyAddress` — CREATE2 Address Prediction

**Location:** `src/RWAFactory.sol`

Called off-chain to predict proxy addresses before deployment. The formula is:
```
address = keccak256(0xff ++ factory ++ salt ++ creationCodeHash)[12:]
```

**Yul implementation:**
```solidity
function predictProxyAddress(bytes32 salt, bytes32 creationCodeHash)
    public view returns (address predicted)
{
    assembly {
        let ptr := mload(0x40)
        mstore(0x40, add(ptr, 0x60))
        mstore8(ptr, 0xff)
        mstore(add(ptr, 0x01), shl(0x60, address()))
        mstore(add(ptr, 0x15), salt)
        mstore(add(ptr, 0x35), creationCodeHash)
        predicted := and(keccak256(ptr, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
    }
}
```

**Solidity equivalent:**
```solidity
function predictProxyAddressSolidity(bytes32 salt, bytes32 creationCodeHash)
    public view returns (address)
{
    return address(uint160(uint256(keccak256(
        abi.encodePacked(bytes1(0xff), address(this), salt, creationCodeHash)
    ))));
}
```

**Results:**

| Implementation | Gas (isolated call) | Savings |
|----------------|-------------------|---------|
| Solidity | ~820 gas | baseline |
| Yul | ~580 gas | ~29% |

The Yul version avoids `abi.encodePacked` which allocates a new bytes array in memory, copies data into it, then passes it to `keccak256`. The Yul version writes directly into free memory at `mload(0x40)` without intermediate allocation.

**Test:** `test_PredictProxy_YulMatchesSolidity` and `testFuzz_PredictProxy_YulMatchesSolidity` confirm identical outputs.

---

### 2.3 `_sqrt` — Babylonian Square Root

**Location:** `src/RWAPool.sol`

Used once per pool — only on the first liquidity deposit to compute `sqrt(amount0 * amount1)`.

**Yul implementation:**
```solidity
function _sqrt(uint256 y) internal pure returns (uint256 z) {
    assembly ("memory-safe") {
        switch gt(y, 3)
        case 1 {
            z := y
            let x := add(div(y, 2), 1)
            for {} lt(x, z) {} {
                z := x
                x := div(add(div(y, x), x), 2)
            }
        }
        default {
            if iszero(iszero(y)) { z := 1 }
        }
    }
}
```

**Solidity equivalent (for reference):**
```solidity
function _sqrtSolidity(uint256 y) internal pure returns (uint256 z) {
    if (y > 3) {
        z = y;
        uint256 x = y / 2 + 1;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    } else if (y != 0) {
        z = 1;
    }
}
```

**Results:**

| Implementation | Gas (1e36 input) | Savings |
|----------------|-----------------|---------|
| Solidity | ~2,100 gas | baseline |
| Yul | ~1,650 gas | ~21% |

The Babylonian method converges in O(log log y) iterations. For typical LP amounts around 10,000 ether, it takes ~6 iterations. The Yul version saves gas on each iteration by avoiding Solidity's overflow checks on division and addition.

---

## 3. Key Function Gas Costs

Measured from `forge test --gas-report`:

### RWAToken

| Function | Gas |
|----------|-----|
| initialize | ~250,000 |
| issue (first call) | ~83,000 |
| issue (subsequent) | ~51,000 |
| redeem | ~36,000 |
| updateCollateral | ~28,000 |
| upgradeToAndCall (V1→V2) | ~180,000 |

### RWAPool

| Function | Gas |
|----------|-----|
| addLiquidity (first deposit) | ~236,000 |
| addLiquidity (subsequent) | ~157,000 |
| removeLiquidity | ~118,000 |
| swap | ~80,000 |
| getAmountOut (view) | ~260 |

### RWAFactory

| Function | Gas |
|----------|-----|
| constructor (deploy impls) | ~4,800,000 |
| onboardAsset | ~891,000 |
| predictProxyAddress | ~580 |

### RWAVault

| Function | Gas |
|----------|-----|
| deposit | ~113,000 |
| withdraw | ~132,000 |
| depositYield | ~88,000 |

### RWAStaking

| Function | Gas |
|----------|-----|
| stake | ~80,000 |
| withdraw | ~62,000 |
| claimReward | ~55,000 |
| exit | ~100,000 |

### RWAGovernor

| Function | Gas |
|----------|-----|
| propose | ~76,000 |
| castVote | ~80,000 |
| queue | ~120,000 |
| execute | ~160,000 |

---

## 4. Optimization Techniques Applied

### 4.1 `via_ir = true`

The IR pipeline (`--via-ir`) applies additional optimizations that the legacy pipeline cannot:

- **Stack allocation optimization** — the optimizer can reuse stack slots across branches, reducing stack depth. This was required in `RWAFactory.onboardAsset` which had too many local variables for the legacy pipeline.
- **Function inlining** — small internal functions are inlined at call sites
- **Dead code elimination** — unreachable branches removed

Enabling `via_ir` does increase compilation time from ~2s to ~42s, but has no runtime gas cost difference.

### 4.2 `optimizer_runs = 200`

The optimizer runs value controls the size/speed tradeoff:
- Low value (1) → optimize for size (small bytecode, higher per-call gas)
- High value (1000+) → optimize for speed (larger bytecode, lower per-call gas)

200 is the standard default, appropriate for contracts that will be called many times (AMM, staking) while keeping deployment costs reasonable.

### 4.3 Custom Errors

All contracts use custom errors instead of string revert messages:

```solidity
// Bad (high gas):
require(amount > 0, "ZeroAmount");    // ~300 extra gas for string storage

// Good (low gas):
error ZeroAmount();
if (amount == 0) revert ZeroAmount(); // ~50 gas
```

Custom errors save approximately 250 gas per revert by avoiding string encoding and storage.

### 4.4 `immutable` Variables

Factory and pool contracts use `immutable` for addresses that don't change:

```solidity
IERC20 public immutable token0;   // read from bytecode, not storage
IERC20 public immutable token1;   // saves ~2,100 gas per read vs SLOAD
```

`immutable` variables are baked into the contract bytecode at deployment time. Reading them costs 3 gas (PUSH) instead of 2,100 gas (SLOAD).

### 4.5 `SafeERC20` Consistently

All token transfers use `SafeERC20.safeTransfer/safeTransferFrom`. While this adds a small overhead (~200 gas) vs direct `.transfer()`, it handles non-standard ERC-20 tokens (USDT, BNB) that don't return `bool`, preventing silent failures.

### 4.6 Packing in Structs

`CertificateData` in `AssetCertificate.sol`:
```solidity
struct CertificateData {
    address rwaToken;   // 20 bytes  ─┐ packed into
    uint96  issuedAt;   // 12 bytes  ─┘ one slot (32 bytes)
    string  assetType;  // separate slot
    address issuer;     // separate slot
}
```

`address` (20 bytes) and `uint96` (12 bytes) sum to exactly 32 bytes — they fit in one storage slot, saving one SSTORE on mint.

*(Note: actual struct uses uint256 for issuedAt for simplicity — this is a recommendation for future optimization.)*

### 4.7 Avoiding Redundant SLOADs

In `RWAPool.swap()`, reserves are cached in local variables before the swap computation:

```solidity
(IERC20 inputToken, IERC20 outputToken, uint256 resIn, uint256 resOut) =
    isToken0
        ? (token0, token1, reserve0, reserve1)
        : (token1, token0, reserve1, reserve0);
```

`reserve0` and `reserve1` are read once from storage (2,100 gas each) and then used from the stack for the rest of the function.

---

## 5. Deployment Cost Summary

| Contract | Deployment gas | Notes |
|----------|---------------|-------|
| GovernanceToken (impl) | ~1,800,000 | UUPS + ERC-20Votes |
| RWAToken (impl) | ~2,100,000 | UUPS + Chainlink |
| RWAVault (impl) | ~1,600,000 | UUPS + ERC-4626 |
| AssetCertificate | ~1,400,000 | ERC-721 + soulbound |
| RWAFactory | ~4,800,000 | deploys 3 contracts internally |
| RWAPool | ~2,200,000 | AMM + LP token |
| RWAGovernor | ~3,500,000 | full OZ governor stack |
| RWATimelock | ~1,100,000 | OZ TimelockController |
| RWAStaking | ~900,000 | staking rewards |
| **Total** | **~19,400,000** | ~0.02 ETH at 1 gwei |

On Arbitrum Sepolia, gas prices are typically 0.01–0.1 gwei, making the full deployment cost approximately **$0.05–$0.50** at current ETH prices.

---

## 6. L1 vs L2 Cost Comparison

Ethereum L1 and Arbitrum One execute the same bytecode but at very different gas prices.
The table below compares transaction costs for key platform operations at representative
gas prices, with ETH at **$3,000**.

| | **Ethereum L1** | **Arbitrum One** | Savings |
|--|--|--|--|
| Gas price assumed | 30 gwei | 0.1 gwei | 300× cheaper |
| Cost per gas unit | $0.00009 | $0.0000003 | — |

### 6.1 Per-Operation Cost Table

| Operation | Gas used | L1 cost (30 gwei) | Arbitrum cost (0.1 gwei) | Reduction |
|-----------|----------|-------------------|--------------------------|-----------|
| `addLiquidity` (first deposit) | ~236,000 | ~$21.24 | ~$0.07 | **303×** |
| `addLiquidity` (subsequent) | ~157,000 | ~$14.13 | ~$0.05 | **303×** |
| `swap` | ~80,000 | ~$7.20 | ~$0.02 | **300×** |
| `stake` | ~80,000 | ~$7.20 | ~$0.02 | **300×** |
| `deposit` (vault) | ~113,000 | ~$10.17 | ~$0.03 | **303×** |
| `propose` (governance) | ~76,000 | ~$6.84 | ~$0.02 | **300×** |
| `onboardAsset` (factory) | ~891,000 | ~$80.19 | ~$0.27 | **300×** |

### 6.2 Full-Platform Deployment Cost

| Network | Total deployment gas | Deployment cost |
|---------|---------------------|-----------------|
| Ethereum L1 (30 gwei) | ~19,400,000 | **~$1,746** |
| Arbitrum One (0.1 gwei) | ~19,400,000 | **~$5.82** |
| Arbitrum Sepolia testnet | ~19,400,000 | **~$0.00** (free testnet ETH) |

### 6.3 Notes on Arbitrum's Fee Model

Arbitrum uses a two-part fee model:

1. **L2 execution fee** — gas × L2 gas price (shown in the table above). This is the dominant
   cost for most transactions.

2. **L1 data fee** — the cost of posting calldata to Ethereum L1 as a batch. This was
   significantly reduced after **EIP-4844 (blob transactions)** shipped in March 2024.
   Blobs cost ~$0.01–$0.05 per transaction (vs $0.50–$2.00 before blobs).

The combined fee for a typical RWA platform swap on Arbitrum One is approximately
**$0.02–$0.07**, making the platform viable for retail users.

### 6.4 Why This Matters for RWA

RWA tokenization involves operations that would be prohibitively expensive on L1:

| Scenario | L1 cost | Arbitrum cost | Comment |
|----------|---------|---------------|---------|
| Retail investor swaps $100 in RWA | ~$7 | ~$0.02 | L1 fee = 7% of trade value |
| Fund onboards new asset | ~$80 | ~$0.27 | One-time cost, amortized |
| DAO governance proposal | ~$7 | ~$0.02 | Enables broad participation |
| Staking reward claim | ~$5 | ~$0.02 | Viable for small positions |

At L1 prices, a $100 swap incurs a 7% fee just in gas — making the platform impractical
for any position under ~$1,000. On Arbitrum, the same swap costs 0.02% in gas, enabling
genuine retail participation.

---

## 7. Future Optimizations

The following optimizations were considered but not implemented to keep the code readable:

1. **Packed reserves in RWAPool** — `reserve0` and `reserve1` could be packed into a single `uint128[2]` storage slot, saving one SLOAD per swap. Estimated saving: ~2,100 gas per swap.

2. **Bitmap roles in AccessControl** — for contracts with many roles, a bitmap-based role system is more gas-efficient than OZ's mapping-based system. Not applied because OZ's system is more auditable.

3. **Transient storage (EIP-1153)** — reentrancy locks could use transient storage (available in Cancun) instead of persistent storage, saving ~20,000 gas per reentrancy-guarded call on the first write. Not applied because `cancun` EVM is configured but the transient storage opcode support in OZ's ReentrancyGuard was not available at development time.
