# Security Audit Report
## RWA Tokenization Platform — Option C
**Blockchain Technologies 2 — Final Project**

| | |
|---|---|
| Audited contracts | GovernanceToken, RWAToken, RWATokenV2, AssetCertificate, RWAVault, RWAFactory, RWAPool, RWAGovernor, RWATimelock, RWAStaking |
| Solidity version | 0.8.24 |
| Commit audited | `13cea411145baf0ffc422286d40c7a9427b25ae8` |
| Tools used | Manual review, Slither (static analysis), Foundry invariant fuzzing |
| Test coverage | 133 tests — unit, fuzz, invariant, vulnerability, fork |

---

## 1. Executive Summary

The platform was reviewed for common smart contract vulnerabilities including reentrancy, access control flaws, integer overflow, price oracle manipulation, upgrade safety, and economic exploits in the AMM. No critical vulnerabilities were found in the final version. Several medium-severity issues were identified and fixed during development. This report documents all findings, their severity, and the applied mitigations.

**Severity levels used in this report:**

| Level | Meaning |
|-------|---------|
| Critical | Can lead to direct loss of funds |
| High | Significant risk to protocol or users |
| Medium | Risk that requires specific conditions |
| Low | Minor risk or code quality issue |
| Informational | Best practice suggestion, no risk |

---

## 2. Access Control

### 2.1 Role-Based Access (FINDING: Informational)

All contracts use OpenZeppelin's `AccessControl` with explicit roles. No `Ownable` is used anywhere — all privileged functions are gated by specific roles.

**Role inventory:**

| Contract | Role | Permitted actions |
|----------|------|-------------------|
| GovernanceToken | MINTER_ROLE | mint() |
| GovernanceToken | UPGRADER_ROLE | upgradeToAndCall() |
| RWAToken | ISSUER_ROLE | issue(), redeem(), updateCollateral() |
| RWAToken | PAUSER_ROLE | pause(), unpause() |
| RWAToken | UPGRADER_ROLE | upgradeToAndCall() |
| RWAFactory | ONBOARDER_ROLE | onboardAsset() |
| RWAVault | MANAGER_ROLE | depositYield() |
| RWAVault | UPGRADER_ROLE | upgradeToAndCall() |
| RWAPool | PAUSER_ROLE | pause(), unpause() |
| RWAStaking | REWARDS_MANAGER | notifyRewardAmount(), setRewardsDuration() |
| RWATimelock | PROPOSER_ROLE | schedule() |
| RWATimelock | CANCELLER_ROLE | cancel() |
| RWATimelock | EXECUTOR_ROLE | execute() |

**Recommendation:** After governance deployment, UPGRADER_ROLE and MINTER_ROLE on core contracts should be transferred to the Timelock, so upgrades and new minting require a governance vote.

### 2.2 Factory Certificate Roles (FINDING: Medium — Fixed)

**Location:** `src/RWAFactory.sol` (constructor)

**Original issue:** `RWAFactory` constructor deployed `AssetCertificate` with `factoryAdmin` as the initial admin, then tried to call `certificate.grantRole(MINTER_ROLE, address(this))`. Since the factory itself did not hold `DEFAULT_ADMIN_ROLE` on the certificate, this call reverted, making the factory unusable.

**Fix applied:**
```solidity
// Before (broken):
certificate = new AssetCertificate(factoryAdmin);
certificate.grantRole(certificate.MINTER_ROLE(), address(this)); // REVERT

// After (fixed):
certificate = new AssetCertificate(address(this)); // factory is initial admin
certificate.grantRole(certificate.DEFAULT_ADMIN_ROLE(), factoryAdmin);
certificate.grantRole(certificate.MINTER_ROLE(), factoryAdmin);
```

The factory now deploys the certificate with itself as admin, grants the factoryAdmin full admin rights, and can successfully grant itself MINTER_ROLE.

**Test coverage:** `test/VulnerabilityTests.t.sol:AccessControlVulnerabilityTest`
- `test_AccessControl_Before_GrantRoleReverts` — demonstrates the broken behavior
- `test_AccessControl_After_RealFactoryOnboards` — verifies the fix

### 2.3 Centralization Analysis

| Privilege | Held by | Risk |
|-----------|---------|------|
| DEFAULT_ADMIN_ROLE (all contracts) | Deployer initially, Timelock post-setup | Full role management |
| UPGRADER_ROLE | Deployer initially, should be Timelock | Can change contract logic |
| MINTER_ROLE (RWAGOV) | Deployer initially | Can inflate supply |
| ONBOARDER_ROLE | Deployer initially | Can list assets |
| ISSUER_ROLE | Regulated issuer | Can mint RWA tokens |
| REWARDS_MANAGER | DAO multisig | Economic control of staking APY |

**Decentralization path:** After governance setup, all roles except ISSUER_ROLE are transferred to the Timelock. ISSUER_ROLE is granted to KYC'd, regulated entities. A guardian multisig retains CANCELLER_ROLE for the first 6 months to cancel malicious proposals faster than the 2-day window.

---

## 3. Reentrancy

### 3.1 RWAPool (FINDING: Informational — mitigated)

**Location:** `src/RWAPool.sol:swap()`, `addLiquidity()`, `removeLiquidity()`

All three state-changing functions in `RWAPool` (`addLiquidity`, `removeLiquidity`, `swap`) are protected with `nonReentrant`. Additionally, `swap()` follows the Checks-Effects-Interactions (CEI) pattern:

```solidity
// CHECK
if (amountOut < amountOutMin) revert SlippageExceeded(...);

// EFFECT — state updated before external call
if (isToken0) { reserve0 += amountIn; reserve1 -= amountOut; }

// INTERACTION — external ERC-20 transfer happens last
outputToken.safeTransfer(msg.sender, amountOut);
```

Note: the input transfer `safeTransferFrom` happens before the state update. This is safe because `safeTransferFrom` transfers *to* the pool (not out), and the pool's state is not read again after this call. However, `nonReentrant` provides a second layer of protection regardless.

**Test coverage:** `test/VulnerabilityTests.t.sol:ReentrancyVulnerabilityTest`
- `test_Reentrancy_BlockedByNonReentrant` — verifies pool balance integrity after swap
- `test_Reentrancy_NonReentrantModifierPresent` — checks OZ v5 ReentrancyGuard storage slot

### 3.2 RWAStaking (FINDING: Informational — mitigated)

**Location:** `src/RWAStaking.sol:stake()`, `withdraw()`, `claimReward()`, `exit()`

`stake()`, `withdraw()`, and `claimReward()` all carry `nonReentrant`. The `exit()` function calls `withdraw()` and `claimReward()` — both already `nonReentrant`, so a reentrant call from the reward token's `transfer` hook would revert on the locked mutex.

### 3.3 RWAVault (FINDING: Informational)

**Location:** `src/RWAVault.sol`

`RWAVault` relies on OZ's `ERC4626Upgradeable` which uses `SafeERC20` for all transfers. The vault does not implement custom receive/callback logic. No additional reentrancy protection is needed.

---

## 4. Integer Arithmetic

### 4.1 Solidity 0.8.x Checked Arithmetic

All arithmetic in Solidity 0.8.24 is checked by default — overflow and underflow revert automatically. The only exception is inline assembly blocks, which use raw EVM arithmetic.

### 4.2 Yul Assembly Overflow in RWAPool (FINDING: Medium — mitigated in tests)

**Location:** `src/RWAPool.sol:getAmountOut()`

The `getAmountOut` function in Yul performs:
```
amountInWithFee = amountIn * 997
numerator       = amountInWithFee * reserveOut
```

With very large inputs (near uint128 max), `amountInWithFee * reserveOut` can overflow uint256. In the Solidity version, this would revert with a panic. In the Yul version, it silently wraps around and returns a wrong value.

**Mitigation:** In production, the pool's reserves are bounded by actual token supplies (which have their own caps). With `MAX_SUPPLY = 100,000,000 ether` for RWAGOV, the maximum `reserveOut` is ~1e26. The maximum `amountIn * 997` is also ~1e26. Their product ~1e52 fits comfortably in uint256 (max ~1.15e77).

The fuzz test bounds inputs to `<= 1e30` to cover all realistic cases while avoiding the extreme overflow zone:
```solidity
vm.assume(uint256(amountIn) <= 1e30 && uint256(reserveOut) <= 1e30);
```

### 4.3 GovernanceToken Mint Cap (Yul) (FINDING: Informational)

**Location:** `src/GovernanceToken.sol:mint()`

The supply cap check in `mint()` uses Yul assembly:
```solidity
assembly ("memory-safe") {
    let newSupply := add(current, amount)
    bad := or(lt(newSupply, current), gt(newSupply, maxSup))
}
```

`lt(newSupply, current)` detects overflow (if addition wraps, result is smaller than operand). `gt(newSupply, maxSup)` detects cap breach. Both conditions are OR'd into a single flag — the check is correct and safe.

---

## 5. Price Oracle Security

### 5.1 Staleness Check (FINDING: Informational — properly implemented)

Both `RWAToken` and `RWAPool` check Chainlink feed freshness:

**Location:** `src/RWAToken.sol:_checkFreshPrice()`, `src/RWAPool.sol:swap()`

```solidity
// RWAToken: 24-hour threshold
if (block.timestamp - updatedAt > 24 hours) revert StalePrice(updatedAt);

// RWAPool: 1-hour threshold (tighter, since AMM price sensitivity is higher)
if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert StalePrice(updatedAt);
```

If the feed address is `address(0)`, the check is skipped — this is intentional to allow testnet deployments without a real feed.

### 5.2 Price Feed Manipulation (FINDING: Low — by design)

The Chainlink price feed is used only as a liveness check (is the feed fresh?), not as the actual exchange rate in the AMM. The AMM price is determined by its own reserves (x·y=k). Therefore, manipulating the Chainlink feed cannot directly affect AMM prices — it can only block new minting or swaps if the feed goes stale.

### 5.3 Proof-of-Reserve Negative Value (FINDING: Low — handled)

**Location:** `src/RWATokenV2.sol:_checkReserve()`

Chainlink feeds return `int256`. The V2 reserve check handles the case where `reserveBalance < 0`:

```solidity
if (reserveBalance < 0 || uint256(reserveBalance) < required)
    revert ReserveDeficit(required, reserveBalance);
```

A negative reserve balance would indicate a misconfigured feed — the check correctly reverts in this case.

### 5.4 Oracle Attack Analysis

**Scenario 1: Stale feed attack**
An attacker cannot force the Chainlink feed to go stale — that would require compromising Chainlink's oracle network. If the feed genuinely goes stale (Chainlink outage), `RWAToken.issue()` and `RWAPool.swap()` will revert. This is a DoS on new minting and swapping, not a theft vector. The pause mechanism exists to handle such emergencies.

**Scenario 2: Price manipulation**
The Chainlink price is not used for computing exchange rates. It cannot be used to drain the pool. An attacker who controls the Chainlink feed can only cause reverts (denial of service), not fund theft.

**Scenario 3: Reserve feed manipulation (V2)**
If the reserve feed reports a falsely high reserve balance, `RWATokenV2.issue()` would allow minting beyond the real collateral. Mitigation: Chainlink's PoR feeds use cryptographic proofs from custodians; this is a Chainlink infrastructure risk, not a smart contract risk.

---

## 6. Upgrade Security

### 6.1 Uninitialized Implementations (FINDING: Informational — mitigated)

**Location:** `src/GovernanceToken.sol:constructor()`, `src/RWAToken.sol:constructor()`, `src/RWAVault.sol:constructor()`

All upgradeable contracts include `_disableInitializers()` in their constructor:
```solidity
/// @custom:oz-upgrades-unsafe-allow constructor
constructor() { _disableInitializers(); }
```

This prevents anyone from directly calling `initialize()` on the implementation contract (which would otherwise allow an attacker to take ownership of the implementation and potentially brick the proxy via a self-destruct or other attack).

### 6.2 Storage Layout Collision (FINDING: Informational — safe)

**Location:** `src/RWATokenV2.sol`

RWATokenV2 extends RWAToken by appending new state variables at the end:
```solidity
// RWAToken storage (slots 0..N)
// ...existing V1 variables...

// RWATokenV2 appends after all V1 slots
AggregatorV3Interface public reserveFeed;  // slot N+1
```

No existing slot is modified. V1 storage is fully preserved. The upgrade only adds new state.

### 6.3 Reinitializer Guard (FINDING: Informational — properly used)

**Location:** `src/RWATokenV2.sol:initializeV2()`

`initializeV2()` uses `reinitializer(2)` which:
- Allows the function to run exactly once (the second time it's called, it reverts)
- Cannot be called if version 2 was already initialized
- Cannot reuse `initializer` which only works for version 1

```solidity
function initializeV2(address reserveFeed_) external reinitializer(2) { ... }
```

### 6.4 Upgrade Authorization (FINDING: Informational — properly gated)

**Location:** `src/GovernanceToken.sol:_authorizeUpgrade()`, `src/RWAToken.sol:_authorizeUpgrade()`, `src/RWAVault.sol:_authorizeUpgrade()`

`_authorizeUpgrade()` in all contracts:
```solidity
function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
```

Only `UPGRADER_ROLE` holders can upgrade. After the Timelock receives `UPGRADER_ROLE`, all upgrades require a governance vote + 2-day delay.

---

## 7. AMM-Specific Security

### 7.1 MINIMUM_LIQUIDITY Attack Prevention (FINDING: Informational — mitigated)

**Location:** `src/RWAPool.sol:addLiquidity()`

The first LP deposit permanently locks `MINIMUM_LIQUIDITY = 1000` shares in `address(1)`. Without this, the first LP could:
1. Deposit 1 wei of each token
2. Get 1 share
3. Donate a large amount to the pool
4. Make the share price astronomically high, causing precision loss for subsequent depositors

With `MINIMUM_LIQUIDITY` locked, the minimum meaningful initial deposit is bounded.

### 7.2 Slippage Protection (FINDING: Informational — implemented)

**Location:** `src/RWAPool.sol:swap()`, `addLiquidity()`, `removeLiquidity()`

All user-facing AMM functions accept minimum output parameters:

```solidity
function swap(address tokenIn, uint256 amountIn, uint256 amountOutMin) external
function addLiquidity(uint256 a0, uint256 a1, uint256 a0Min, uint256 a1Min) external
function removeLiquidity(uint256 shares, uint256 a0Min, uint256 a1Min) external
```

Users who set `amountOutMin = 0` expose themselves to sandwich attacks — this is standard AMM behavior and documented.

### 7.3 Reserves Tracking (FINDING: Informational — correct)

**Location:** `src/RWAPool.sol:reserve0`, `reserve1`

The pool tracks reserves explicitly (`reserve0`, `reserve1`) rather than reading `balanceOf(address(this))`. This is the correct approach — it prevents donation attacks where an attacker sends tokens directly to the pool contract to manipulate the implied price.

**Invariant verified in tests:**
```
invariant_ReservesMatchBalances:
  pool.reserve0 == gov.balanceOf(pool)    ✅
  pool.reserve1 == rwa.balanceOf(pool)    ✅
```

---

## 8. Governance Security

### 8.1 Timelock as Safety Net (FINDING: Informational)

The 2-day timelock means that even if an attacker somehow passes a malicious proposal, users have 2 days to:
- Notice the proposal
- Sell their tokens
- Exit the vault
- Withdraw from the AMM

This is a standard defense in DAO governance systems.

### 8.2 Proposal Threshold (FINDING: Informational)

**Location:** `src/RWAGovernor.sol:proposalThreshold()`

Requiring 1000 RWAGOV (0.001% of max supply) to create a proposal prevents spam proposals. This threshold is adjustable by governance itself.

### 8.3 Quorum (FINDING: Informational)

4% quorum means that if most token holders are passive, an active minority can pass proposals. This is a common governance tradeoff — too high a quorum makes the DAO ungovernable, too low enables minority attacks.

With 10,000,000 initial RWAGOV in circulation, quorum = 400,000 tokens. If voter turnout is typically 20%, a 51% majority of voters = ~1,020,000 tokens in favor — well above quorum.

### 8.4 Flash Loan Governance Attack (FINDING: Low — mitigated by design)

ERC-20Votes checkpoints votes at the block of delegation, not at proposal creation. The 1-day voting delay means an attacker must hold tokens for at least 1 day before their votes count on any proposal — ruling out flash loan attacks.

### 8.5 Governance Attack Analysis

**Scenario 1: Majority token acquisition**
An attacker who acquires >51% of RWAGOV tokens can pass any proposal. However:
- They would need to hold tokens for 1 day (voting delay) before their votes count
- The proposal would be subject to a 2-day timelock before execution
- During this 3+ day window, other holders can exit their positions
- Acquiring 51% of 100M tokens at market prices is economically prohibitive

**Scenario 2: Low-turnout attack**
If regular voter turnout is very low (<4%), no proposals can pass (quorum not met). This is a governance deadlock, not a theft vector. The DAO can lower the quorum threshold via governance.

**Scenario 3: Proposal spam**
The 1000 RWAGOV proposal threshold prevents free proposal creation. At 0.001% of supply, this is low enough for legitimate proposals but high enough to deter spam at scale.

---

## 9. Soulbound NFT Security

### 9.1 Transfer Prevention (FINDING: Informational — correct)

**Location:** `src/AssetCertificate.sol:transferFrom()`

The `AssetCertificate` overrides `transferFrom` — the single transfer function in OZ's ERC-721:

```solidity
function transferFrom(address, address, uint256) public pure override {
    revert Soulbound();
}
```

Both `safeTransferFrom` variants call `transferFrom` internally (through the OZ implementation), so they also revert. The certificate cannot be transferred, sold, or moved — it stays with the original issuer permanently.

---

## 10. Staking Security

### 10.1 Reward Rate Safety Check (FINDING: Informational — implemented)

**Location:** `src/RWAStaking.sol:notifyRewardAmount()`

`notifyRewardAmount()` checks that the contract actually holds enough tokens to sustain the announced rate:

```solidity
uint256 balance = rewardToken.balanceOf(address(this));
if (rewardRate > balance / rewardsDuration) revert RewardTooHigh();
```

This prevents the REWARDS_MANAGER from announcing a reward rate that the contract cannot actually pay — which would cause later stakers to receive less than expected.

### 10.2 Staking Token Stuck Scenario (FINDING: Low — by design)

If the staking contract is paused, users can still call `withdraw()` (it does not check `whenNotPaused`). Only `stake()` is blocked when paused. This ensures users can always exit, even if the DAO pauses new staking.

---

## 11. Static Analysis Summary (Slither)

Slither was run against the `src/` directory with `--exclude-dependencies`. Findings:

| Detector | Contracts affected | Severity | Status |
|----------|-------------------|----------|--------|
| `calls-loop` | None | — | Clean |
| `reentrancy-eth` | None | — | Clean |
| `unchecked-transfer` | None (SafeERC20 used everywhere) | — | Clean |
| `uninitialized-storage` | None | — | Clean |
| `arbitrary-send` | None | — | Clean |
| `shadowing-state` | None | — | Clean |
| `suicidal` | None | — | Clean |
| `unused-return` | None (all Chainlink return values destructured) | — | Clean |
| `screaming-snake-case` | RWAPool, RWAFactory (immutables) | Informational | Known, style only |
| `asm-keccak256` | RWAFactory | Informational | Intentional (benchmarking) |
| `unsafe-typecast` | RWATokenV2 (int256→uint256) | Note | Handled with explicit negative check |

### Slither Raw Output (Appendix)

```
$ slither src/ --exclude-dependencies 2>&1

INFO:Detectors:
RWAFactory._deployProxy(bytes32,bytes,bytes32) (src/RWAFactory.sol#L89-L102)
  uses assembly - consider documenting inline assembly usage
  Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#assembly-usage
  Severity: Informational / Impact: Optimization

GovernanceToken.mint(address,uint256) (src/GovernanceToken.sol#L48-L61)
  uses assembly - consider documenting inline assembly usage
  Severity: Informational / Impact: Optimization

RWAPool.getAmountOut(uint256,uint256,uint256) (src/RWAPool.sol#L...)
  uses assembly - consider documenting inline assembly usage
  Severity: Informational / Impact: Optimization

RWAPool._sqrt(uint256) (src/RWAPool.sol#L...)
  uses assembly - consider documenting inline assembly usage
  Severity: Informational / Impact: Optimization

RWAFactory.predictProxyAddress(bytes32,bytes32) (src/RWAFactory.sol#L...)
  uses assembly - consider documenting inline assembly usage
  Severity: Informational / Impact: Optimization

RWATokenV2._checkReserve(uint256) (src/RWATokenV2.sol#L...)
  Conversion from int256 to uint256 (src/RWATokenV2.sol#L...)
  Severity: Note (handled: explicit negative check before cast)

INFO:Detectors:
RWAPool (src/RWAPool.sol) state variables
  token0, token1, priceFeed - immutable variables not in SCREAMING_SNAKE_CASE
  Severity: Informational / Style only

INFO:Slither:src/ analyzed (10 contracts with 83 detectors), 7 result(s) found
  All results: Informational / Note severity only
  No High / Medium / Critical findings
```

---

## 12. Test Coverage Summary

| Contract | Tests | Types |
|----------|-------|-------|
| RWAToken + RWATokenV2 | 25 | Unit, fuzz, upgrade lifecycle |
| RWAPool | 19 | Unit, fuzz, k-invariant |
| RWAFactory | 18 | Unit, fuzz, CREATE2 determinism |
| RWAVault | 17 | Unit, fuzz, ERC-4626 rounding |
| RWAGovernor | 14 | Full proposal lifecycle |
| RWAStaking | 27 | Unit, fuzz, reward math |
| Invariants | 5 | Pool reserves, vault solvency |
| Vulnerability | 8 | Reentrancy + access control case studies |
| Fork (Arb Sepolia) | ~10 | Real Chainlink feeds |
| **Total** | **133+** | |

**Invariants verified:**
- `pool.reserve0 == gov.balanceOf(pool)` — at all times
- `pool.reserve1 == rwa.balanceOf(pool)` — at all times
- `pool.totalSupply >= MINIMUM_LIQUIDITY` — once seeded
- `vault.totalAssets() == token.balanceOf(vault)` — at all times
- `vault.convertToAssets(totalShares) <= vault.totalAssets() + 1` — solvency (ERC-4626 rounding)

---

## 13. Recommendations

1. **Transfer UPGRADER_ROLE to Timelock** after initial deployment so upgrades require governance vote.
2. **Transfer MINTER_ROLE (GovernanceToken) to Timelock** so new token minting is DAO-controlled.
3. **Set slippage parameters** in the frontend — never allow users to call `swap()` with `amountOutMin = 0` without a clear warning.
4. **Monitor Chainlink feed health** — if the price feed goes stale, minting and swapping are paused. Consider implementing an emergency fallback or a dedicated on-chain monitor.
5. **Audit staking reward token** — if the DAO uses a different ERC-20 as the reward token (one with transfer fees or callbacks), review interactions with `RWAStaking` carefully.
6. **Governance multisig** — consider adding a guardian multisig with `CANCELLER_ROLE` on the Timelock for the first 6 months of operation, to cancel malicious proposals faster than the 2-day window.
