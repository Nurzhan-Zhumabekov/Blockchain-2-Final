# Architecture Document
## RWA Tokenization Platform — Option C
**Blockchain Technologies 2 — Final Project**

| | |
|---|---|
| Team | Nurzhan Zhumabekov, Abylay Abdykassymov, Abilkhaiyr Sarsenbay |
| Network | Arbitrum Sepolia, Base Sepolia |
| Framework | Foundry |
| Solidity | 0.8.24 |
| EVM | Cancun |

---

## 1. Overview

The RWA Tokenization Platform lets issuers bring real-world assets (government bonds, commodities, real estate) on-chain as ERC-20 tokens. Token holders can deposit into a yield-bearing vault, trade on an AMM, stake for additional rewards, and govern the protocol through a DAO.

The platform is designed around three principles:

- **Non-custodial** — the factory deploys independent proxy contracts per asset, so each issuer owns their token and vault
- **Upgradeable** — all core contracts use the UUPS proxy pattern, and the V1→V2 migration adds Proof-of-Reserve enforcement without changing contract addresses
- **Governed** — all privileged actions (new asset onboarding, upgrades, parameter changes) flow through the Governor + Timelock

---

## 2. System Diagram

```
                        ┌─────────────────┐
                        │   RWAGOV Holder  │
                        └────────┬────────┘
                                 │ delegate + vote
                    ┌────────────▼──────────────┐
                    │       RWAGovernor          │
                    │  (OZ Governor stack)       │
                    └────────────┬──────────────┘
                                 │ queue / execute
                    ┌────────────▼──────────────┐
                    │       RWATimelock          │
                    │  (2-day execution delay)   │
                    └──┬──────────┬─────────────┘
                       │          │
          upgrade/admin│          │onboard asset
                       │          │
         ┌─────────────▼──┐  ┌───▼──────────────┐
         │ GovernanceToken │  │    RWAFactory     │
         │ (RWAGOV proxy) │  │ (CREATE + CREATE2)│
         └─────────────────┘  └───┬──────────┬───┘
                                  │          │
                    ┌─────────────▼─┐  ┌─────▼──────────┐
                    │  RWAToken     │  │    RWAVault     │
                    │  (proxy V1)   │  │  (ERC-4626      │
                    │      │        │  │   proxy)        │
                    │  RWATokenV2   │  └─────────────────┘
                    │  (proxy V2 +  │
                    │   PoR check)  │
                    └──────┬────────┘
                           │ swap
                    ┌──────▼────────┐
                    │   RWAPool     │◄── Chainlink
                    │  (x·y=k AMM) │    price feed
                    └──────┬────────┘
                           │ stake RWAGOV
                    ┌──────▼────────┐
                    │  RWAStaking   │
                    │  (rewards)    │
                    └───────────────┘
```

---

## 3. Sequence Diagrams

### 3.1 Token Swap (RWAGOV → RWAToken)

```
User          RWAPool          GovernanceToken    RWAToken      Chainlink Feed
 │                │                  │               │                │
 │─ approve(pool) ──────────────────►│               │                │
 │◄──────────────────────────────────│               │                │
 │                │                  │               │                │
 │─ swap(gov, 1000e18, minOut) ──────►│               │                │
 │                │                  │               │                │
 │                │─ latestRoundData() ──────────────────────────────►│
 │                │◄── (price, updatedAt) ───────────────────────────│
 │                │                  │               │                │
 │                │  [staleness check: block.timestamp - updatedAt <= 1h]
 │                │                  │               │                │
 │                │  [reentrancy lock SET]            │                │
 │                │                  │               │                │
 │                │  amountOut = getAmountOut(1000e18, resIn, resOut) │
 │                │  [slippage check: amountOut >= minOut]            │
 │                │                  │               │                │
 │                │  reserve0 += 1000e18              │                │
 │                │  reserve1 -= amountOut            │                │
 │                │                  │               │                │
 │                │─ safeTransferFrom(user, pool, 1000e18) ──────────►│ (gov)
 │                │◄───────────────────────────────────────────────── │
 │                │                  │               │                │
 │                │─ safeTransfer(user, amountOut) ──────────────────►│ (rwa)
 │                │◄───────────────────────────────────────────────── │
 │                │                  │               │                │
 │                │  [reentrancy lock CLEAR]          │                │
 │                │                  │               │                │
 │◄─ Swap event ──│                  │               │                │
```

### 3.2 Governance Proposal Lifecycle

```
Proposer        RWAGovernor      RWATimelock      Target Contract
   │                 │                │                  │
   │─ delegate(self) ────────────────────────────────────────► GovernanceToken
   │                 │                │                  │
   │─ propose(targets, values, calldatas, desc) ──────────────►│
   │                 │                │                  │
   │  [1-day voting delay — blocks advance]
   │                 │                │                  │
Voter              │                │                  │
   │─ castVote(proposalId, 1=FOR) ──►│                  │
   │◄─ VoteCast event ──────────────│                  │
   │                 │                │                  │
   │  [1-week voting period — blocks advance]
   │                 │                │                  │
   │  [proposal.state == Succeeded]   │                  │
   │                 │                │                  │
   │─ queue(targets, values, calldatas, descHash) ──────►│
   │                 │─ schedule(target, value, data, ..., delay) ────►│
   │                 │                │                  │
   │  [2-day timelock delay — wall-clock time passes]
   │                 │                │                  │
   │─ execute(targets, values, calldatas, descHash) ─────►│
   │                 │─ execute(target, value, data, ...) ────────────►│
   │                 │                │─ (call) ─────────────────────►│
   │                 │                │◄─────────────────────────────│
   │◄─ ProposalExecuted event ───────│                  │
```

### 3.3 Vault Deposit and Yield Distribution

```
User            RWAVault           RWAToken          Manager
  │                │                   │                │
  │─ approve(vault, 1000e18) ─────────►│                │
  │                │                   │                │
  │─ deposit(1000e18, user) ──────────►│                │
  │                │─ safeTransferFrom(user, vault, 1000e18) ─────────►│
  │                │◄──────────────────────────────────────────────────│
  │                │  [mint shares: shares = 1000e18 * totalShares / totalAssets]
  │                │  (first deposit: shares = 1000e18, 1:1)           │
  │◄─ shares = 1000e18 (vRWA) ────────│                │                │
  │                │                   │                │
  │            [time passes — asset accrues real-world yield]
  │                │                   │                │
  │                │─ depositYield(500e18) ◄────────────────────────────│
  │                │  [requires MANAGER_ROLE]           │                │
  │                │─ safeTransferFrom(manager, vault, 500e18) ─────────►│
  │                │◄──────────────────────────────────────────────────│
  │                │  totalAssets: 1000e18 → 1500e18    │                │
  │                │  (shares unchanged, price per share rises)         │
  │                │                   │                │
  │─ withdraw(shares, user, user) ─────►│               │
  │                │  assets = shares * totalAssets / totalShares       │
  │                │         = 1000e18 * 1500e18 / 1000e18 = 1500e18   │
  │                │─ safeTransfer(user, 1500e18) ──────────────────────►│
  │◄─ 1500e18 RWAToken (profit = 500e18) ─────────────│                │
```

---

## 4. Smart Contracts

### 4.1 GovernanceToken (RWAGOV)

**File:** `src/GovernanceToken.sol`

The governance token is a UUPS-upgradeable ERC-20 with voting and permit extensions. It is the centerpiece of the DAO.

**Key design decisions:**

- Inherits `ERC20VotesUpgradeable` — checkpointed vote tracking with `delegate()`. Every token holder must delegate (at least to themselves) before their votes count in governance.
- Inherits `ERC20PermitUpgradeable` — gasless approvals via EIP-2612 signatures.
- `MAX_SUPPLY = 100,000,000 RWAGOV` — the cap is enforced in `mint()` using Yul assembly to detect both overflow and cap violation in a single check.
- `MINTER_ROLE` controls who can mint. Initially held by the deployer, should be transferred to the Timelock so only governance can mint new tokens.

**Storage layout (proxy-safe):**

| Slot range | Contract | Variables |
|-----------|---------|-----------|
| 0 | `Initializable` | `_initialized` (uint64), `_initializing` (bool) packed |
| 1..50 | `ERC20Upgradeable` | `_balances`, `_allowances`, `_totalSupply`, `_name`, `_symbol` |
| 51..100 | `ERC20VotesUpgradeable` | `_delegate`, `_checkpoints`, `_totalCheckpoints` |
| 101..150 | `ERC20PermitUpgradeable` | `_nonces`, `DOMAIN_SEPARATOR` cache |
| 151..200 | `AccessControlUpgradeable` | `_roles` mapping |
| 201 | `GovernanceToken` | (no new slots — all vars are immutable/constant) |

---

### 4.2 RWAToken (V1)

**File:** `src/RWAToken.sol`

An asset-backed ERC-20 where each token represents one unit of a real-world asset. Only authorized issuers can mint, and every mint checks the Chainlink price feed for freshness.

**Key design decisions:**

- `ISSUER_ROLE` — only approved issuers can call `issue()`. Gating at the role level, not the function level, means the DAO can revoke issuance rights without upgrading the contract.
- Chainlink staleness check — `_checkFreshPrice()` reads `latestRoundData()` and reverts if `block.timestamp - updatedAt > 24 hours`. If `priceFeed == address(0)`, the check is skipped (useful for testnets without a feed).
- `issue()` is declared `virtual` — this is the extension point for V2.
- `totalCollateral` — an informational field updated by the issuer to track off-chain backing. Not enforced on-chain in V1.

**Role matrix:**

| Role | Can do |
|------|--------|
| DEFAULT_ADMIN_ROLE | Grant/revoke other roles, set price feed |
| ISSUER_ROLE | issue(), redeem(), updateCollateral() |
| PAUSER_ROLE | pause(), unpause() |
| UPGRADER_ROLE | Authorize UUPS upgrades |

**Storage layout:**

| Slot range | Contract | Variables |
|-----------|---------|-----------|
| 0..50 | `ERC20Upgradeable` | balances, allowances, name, symbol |
| 51..100 | `ERC20PausableUpgradeable` | `_paused` |
| 101..150 | `AccessControlUpgradeable` | `_roles` mapping |
| 151 | `RWAToken` | `priceFeed` (address) |
| 152 | `RWAToken` | `assetType` (string) |
| 153 | `RWAToken` | `totalCollateral` (uint256) |

---

### 4.3 RWATokenV2 (Proof-of-Reserve)

**File:** `src/RWATokenV2.sol`

V2 adds Chainlink Proof-of-Reserve enforcement without breaking the existing proxy. Any new `issue()` call must pass both the price feed staleness check (inherited from V1) and the reserve sufficiency check.

**Upgrade path:**
```
1. Deploy RWATokenV2 (new implementation contract)
2. Admin calls: proxy.upgradeToAndCall(
       address(v2Impl),
       abi.encodeCall(RWATokenV2.initializeV2, (reserveFeedAddress))
   )
3. reinitializer(2) ensures initializeV2 runs exactly once
4. All subsequent issue() calls enforce: reserveBalance >= totalSupply + amount
```

**Storage safety:**
V2 appends `reserveFeed` after all V1 storage slots. It does not modify any existing slot, so upgrading cannot corrupt existing balances or roles.

**Storage layout (V2 extension):**

| Slot | Contract | Variable |
|------|---------|---------|
| 154 | `RWATokenV2` | `reserveFeed` (address) — appended after all V1 slots |

**Reserve check logic:**
```solidity
function _checkReserve(uint256 additionalAmount) internal view {
    (, int256 reserveBalance, , uint256 updatedAt, ) = reserveFeed.latestRoundData();
    if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert StalePrice(updatedAt);
    uint256 required = totalSupply() + additionalAmount;
    if (reserveBalance < 0 || uint256(reserveBalance) < required)
        revert ReserveDeficit(required, reserveBalance);
}
```

---

### 4.4 AssetCertificate (Soulbound NFT)

**File:** `src/AssetCertificate.sol`

Each onboarded asset receives a soulbound ERC-721 certificate minted to the issuer. It serves as proof of onboarding and carries metadata about the asset.

**Soulbound implementation:**
```solidity
function transferFrom(address, address, uint256) public pure override {
    revert Soulbound();
}
```

`transferFrom` is the only transfer path in OZ's ERC-721 — overriding it with a revert makes all transfers impossible, including `safeTransferFrom` which calls `transferFrom` internally.

**CertificateData struct:**
```
rwaToken  — address of the corresponding RWAToken proxy
assetType — human-readable string ("US-TREASURY-BOND")
issuedAt  — block timestamp of minting
issuer    — original recipient (= issuer address)
```

---

### 4.5 RWAVault (ERC-4626)

**File:** `src/RWAVault.sol`

An ERC-4626 tokenized vault where users deposit RWAToken and receive vault shares (vRWA). The MANAGER_ROLE can deposit real-world yield which increases the share price for all existing depositors.

**Share price mechanics:**
- Initially: 1 vRWA = 1 RWAToken
- After `depositYield(1000)` with 1000 shares outstanding: 1 vRWA = 2 RWAToken
- Late depositors get shares priced at the current rate — they cannot claim yield accrued before they joined

This is the standard ERC-4626 share price mechanism. No custom logic needed — the OZ implementation handles all rounding correctly.

**Key invariant (verified in invariant tests):**
```
token.balanceOf(vault) == vault.totalAssets()  // at all times
```

**Storage layout:**

| Slot range | Contract | Variables |
|-----------|---------|-----------|
| 0..50 | `ERC20Upgradeable` | balances, allowances (vault shares) |
| 51..100 | `ERC4626Upgradeable` | `_asset` (underlying token address) |
| 101..150 | `AccessControlUpgradeable` | `_roles` mapping |
| 151 | `RWAVault` | (no new slots beyond inherited) |

---

### 4.6 RWAFactory (CREATE + CREATE2)

**File:** `src/RWAFactory.sol`

The factory is the entry point for onboarding new assets. It manages shared implementation contracts and deploys per-asset proxies.

**Two deployment patterns:**

| Pattern | Where used | Why |
|---------|-----------|-----|
| CREATE | Constructor: tokenImpl, vaultImpl, certificate | Shared once, address doesn't matter |
| CREATE2 | onboardAsset(): tokenProxy, vaultProxy | Deterministic — address knowable before deployment |

**CREATE2 salt derivation:**
```solidity
// Token proxy: uses the salt as-is
tokenProxy = _deployProxy(tokenImpl, tokenInit, salt);

// Vault proxy: derived salt prevents address collision
bytes32 vaultSalt = keccak256(abi.encode(salt, "vault"));
vaultProxy = _deployProxy(vaultImpl, vaultInit, vaultSalt);
```

**Yul address prediction:**
`predictProxyAddress()` computes the CREATE2 address in inline assembly, benchmarked against `predictProxyAddressSolidity()`. The Yul version saves ~200 gas per call by avoiding ABI encoding overhead.

---

### 4.7 RWAPool (Constant-Product AMM)

**File:** `src/RWAPool.sol`

A from-scratch x·y=k AMM for swapping RWAGOV ↔ RWAToken with a 0.3% fee. LP shares are minted as the "RWAP" ERC-20.

**AMM formula:**

```
amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
```

**Yul implementation (`getAmountOut`):**
```yasm
assembly ("memory-safe") {
    let amountInWithFee := mul(amountIn, 997)
    let numerator       := mul(amountInWithFee, reserveOut)
    let denominator     := add(mul(reserveIn, 1000), amountInWithFee)
    amountOut           := div(numerator, denominator)
}
```

**Initial LP minting (Babylonian sqrt in Yul):**
The first deposit mints `sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY` shares. `MINIMUM_LIQUIDITY = 1000` is permanently locked in `address(1)` to prevent the price manipulation attack where a single LP controls the entire pool.

**Security features:**
- `nonReentrant` on all state-changing functions
- Slippage parameters (`amountOutMin`, `amount0Min`, `amount1Min`) on every user-facing call
- Chainlink staleness check (`STALENESS_THRESHOLD = 1 hour`) on `swap()` and `addLiquidity()`

---

### 4.8 RWAGovernor + RWATimelock

**Files:** `src/RWAGovernor.sol`, `src/RWATimelock.sol`

Standard OpenZeppelin Governor stack with a Timelock for mandatory execution delay.

**Governor configuration:**

| Parameter | Value | Meaning |
|-----------|-------|---------|
| votingDelay | 1 day (in blocks) | Time between proposal creation and vote start |
| votingPeriod | 1 week (in blocks) | Duration of voting window |
| proposalThreshold | 1000 RWAGOV | Tokens needed to create a proposal |
| quorumNumerator | 4% | Fraction of total supply that must vote FOR |
| timelockDelay | 2 days | Mandatory wait after proposal passes before execution |

**Proposal lifecycle:**
```
propose() → [1 day] → Active (castVote) → [1 week] →
Succeeded → queue() → [2 days] → execute()
```

**Role setup after deployment:**
```
Timelock.PROPOSER_ROLE  → Governor
Timelock.CANCELLER_ROLE → Governor
Timelock.EXECUTOR_ROLE  → address(0) (anyone can execute after delay)
Timelock.DEFAULT_ADMIN_ROLE → revoked from deployer
```

---

### 4.9 RWAStaking

**File:** `src/RWAStaking.sol`

Synthetix-style staking rewards. RWAGOV holders stake and earn RWAToken rewards at a rate set by the DAO.

**Reward accumulation:**
```
rewardPerToken += (elapsed * rewardRate * 1e18) / totalStaked
earned(user)    = balance[user] * (rewardPerToken - userRewardPerTokenPaid[user]) / 1e18
                  + rewards[user]
```

This formula is O(1) per user regardless of how many other stakers exist — no loops needed.

**Reward period:**
The REWARDS_MANAGER calls `notifyRewardAmount(amount)` after transferring reward tokens to the contract. If a period is still active, the remaining reward is rolled into the new rate.

---

## 5. Deployment Flow

```
Step 1 — Deploy core platform (Deploy.s.sol)
  ├─ Deploy GovernanceToken impl + ERC1967Proxy
  ├─ Deploy RWAFactory
  │    ├─ CREATE: RWAToken impl
  │    ├─ CREATE: RWAVault impl
  │    └─ CREATE: AssetCertificate
  ├─ factory.onboardAsset(salt, issuer, ...) 
  │    ├─ CREATE2: RWAToken proxy
  │    ├─ CREATE2: RWAVault proxy
  │    └─ certificate.mint(issuer, tokenProxy, assetType)
  ├─ Deploy RWAPool(govProxy, tokenProxy, priceFeed, admin)
  └─ govToken.mint(deployer, 10_000_000 RWAGOV)

Step 2 — Deploy governance (DeployGovernance.s.sol)
  ├─ Deploy RWATimelock(2 days, [], [address(0)], admin)
  ├─ Deploy RWAGovernor(govToken, timelock)
  ├─ timelock.grantRole(PROPOSER_ROLE, governor)
  ├─ timelock.grantRole(CANCELLER_ROLE, governor)
  └─ timelock.revokeRole(DEFAULT_ADMIN_ROLE, deployer)

Step 3 — Upgrade RWAToken to V2 (UpgradeRWAToken.s.sol)
  ├─ Deploy RWATokenV2 (new implementation)
  └─ proxy.upgradeToAndCall(v2Impl, initializeV2(reserveFeed))

Step 4 — Deploy staking (DeployStaking.s.sol)
  └─ Deploy RWAStaking(govToken, rwaToken, admin, 7 days)
```

---

## 6. Proxy Pattern (UUPS)

All upgradeable contracts use the Universal Upgradeable Proxy Standard (EIP-1822 / EIP-1967).

```
User Transaction
      │
      ▼
┌─────────────┐   delegatecall   ┌─────────────────┐
│ ERC1967Proxy│ ───────────────► │  Implementation  │
│  (storage)  │                  │  (logic only)    │
└─────────────┘                  └─────────────────┘
      │
      │ EIP-1967 slot:
      │ keccak256("eip1967.proxy.implementation") - 1
      ▼
  implementation address
```

**Why UUPS over TransparentProxy:**
- UUPS upgrade logic lives in the implementation — cheaper to deploy (no extra proxy admin contract)
- `_authorizeUpgrade()` gated by `UPGRADER_ROLE` — only role holders can upgrade
- `_disableInitializers()` in every implementation constructor prevents direct initialization of the implementation

---

## 7. Design Patterns

### 7.1 Proxy Pattern (UUPS) — `src/GovernanceToken.sol`, `src/RWAToken.sol`, `src/RWAVault.sol`

**Justification:** RWA assets exist in a regulatory environment that changes over time. Upgradeability is not a luxury but a requirement — without it, a regulatory change (e.g., mandatory Proof-of-Reserve) would require migrating all user balances to a new contract. UUPS was chosen over Transparent Proxy because it saves one contract deployment per upgradeable contract and is simpler to reason about.

### 7.2 Factory Pattern — `src/RWAFactory.sol`

**Justification:** Each real-world asset needs its own independent token and vault. A factory ensures that all deployed instances share the same audited implementation bytecode, and that deployment is deterministic (CREATE2). Without a factory, each issuer would deploy manually with no guarantee of code consistency.

### 7.3 Access Control Pattern (RBAC) — all contracts

**Justification:** Different actors have different permission levels — issuers can mint, managers can deposit yield, upgraders can upgrade, the pauser can pause. Role-Based Access Control (OZ AccessControl) is more fine-grained than `Ownable` and allows the DAO to grant or revoke individual capabilities without giving full ownership. Roles can be transferred to the Timelock incrementally.

### 7.4 Checks-Effects-Interactions (CEI) — `src/RWAPool.sol:swap()`

**Justification:** Prevents reentrancy exploits where an attacker's callback (inside a token transfer) could call back into the pool before its state was updated. In `swap()`, slippage checks are done first (Checks), then reserves are updated (Effects), then the token transfer happens (Interactions). Combined with `nonReentrant`, this gives two independent layers of reentrancy protection.

### 7.5 Pull-over-Push for Rewards — `src/RWAStaking.sol`

**Justification:** Synthetix-style staking uses a lazy accumulation formula: rewards are computed on demand when a user calls `claimReward()`, rather than being pushed to every staker's address on each block. This avoids unbounded loops (no iteration over all stakers), makes gas per-user O(1), and eliminates the griefing vector where sending tokens to many addresses could fail and lock others' rewards.

### 7.6 Soulbound NFT Pattern — `src/AssetCertificate.sol`

**Justification:** Asset certificates are identity-bound proof of onboarding. They must stay with the original issuer and cannot be sold or transferred. Overriding `transferFrom` with a revert is the minimal Solidity implementation — it requires no additional state, no transfer whitelist, and no complex ownership logic. The certificate is immutable proof of fact.

### 7.7 Snapshot / Checkpoint Voting — `GovernanceToken` via `ERC20Votes`

**Justification:** Governance votes are tallied against token balances at a past block, not the current block. This prevents flash-loan attacks where an attacker borrows tokens, votes, and returns them in a single transaction. ERC20Votes from OpenZeppelin checkpoints balances at every transfer, so the Governor can query historical balances at the snapshot block.

---

## 8. Architecture Decision Records (ADRs)

### ADR-001 — Use UUPS over Transparent Proxy

**Status:** Accepted

**Context:** All core contracts need upgradeability. OpenZeppelin offers two patterns: TransparentUpgradeableProxy and UUPSUpgradeable.

**Decision:** Use UUPS.

**Consequences:**
- Pro: One fewer contract per deployable (no ProxyAdmin)
- Pro: Upgrade logic is in the implementation — auditors review one codebase
- Con: If `_authorizeUpgrade` has a bug, the proxy could become non-upgradeable or be taken over
- Mitigation: `UPGRADER_ROLE` controlled by Timelock; `_disableInitializers()` in every constructor

---

### ADR-002 — From-Scratch AMM over Uniswap Fork

**Status:** Accepted

**Context:** The platform needs a token swap mechanism. Options: fork Uniswap v2, use an existing DEX, or implement from scratch.

**Decision:** Implement from scratch with the same x·y=k formula and 0.3% fee.

**Consequences:**
- Pro: Demonstrates understanding of AMM mechanics
- Pro: No dependency on Uniswap's license or external contracts
- Pro: Can embed Yul optimizations and add Chainlink integration natively
- Con: Less battle-tested than Uniswap
- Mitigation: Invariant tests verify k never decreases; fuzz tests verify output formulas

---

### ADR-003 — Separate Vault per Asset (ERC-4626)

**Status:** Accepted

**Context:** Yield distribution could be handled in the RWAToken itself (yield-bearing token) or in a separate vault.

**Decision:** Separate ERC-4626 vault per asset.

**Consequences:**
- Pro: Clean separation of concerns — RWAToken = proof of ownership, Vault = yield accrual
- Pro: ERC-4626 is a widely implemented standard — composable with other DeFi protocols
- Pro: Users who don't want yield can hold raw RWAToken without gas overhead of vault mechanics
- Con: Two contracts per asset instead of one

---

### ADR-004 — Chainlink for Price and Reserve Feeds

**Status:** Accepted

**Context:** Price feeds are needed for RWAToken minting and for monitoring pool health. Options: Chainlink, Pyth, UNIv3 TWAP, centralized oracle.

**Decision:** Use Chainlink AggregatorV3Interface.

**Consequences:**
- Pro: Industry standard, used in Aave, Compound, Synthetix
- Pro: Proof-of-Reserve feeds natively available for US Treasuries
- Pro: Staleness detection built into interface (`updatedAt`)
- Con: Chainlink is a trusted third party — if their feed is compromised, so is the protocol
- Mitigation: Staleness check reverts if feed not updated in 24h (RWAToken) / 1h (RWAPool)

---

### ADR-005 — Soulbound Certificate over On-Chain Registry

**Status:** Accepted

**Context:** After onboarding, we need a durable record that an asset exists and who the issuer is. Options: mapping in the factory, a separate registry contract, or an NFT.

**Decision:** Soulbound ERC-721 NFT.

**Consequences:**
- Pro: NFT is self-describing — carries metadata (assetType, issuer, issuedAt, tokenAddress)
- Pro: Viewable in any NFT wallet or explorer without custom tooling
- Pro: Transferability is explicitly blocked, satisfying regulatory "know your issuer" requirement
- Con: Slightly more gas than a simple mapping (~1.4M deployment gas for AssetCertificate)

---

### ADR-006 — Synthetix Staking Rewards over Merkle Airdrop

**Status:** Accepted

**Context:** RWAGOV holders should earn RWAToken rewards for participating in governance/staking. Options: periodic Merkle airdrops, streaming payment, or Synthetix-style accumulation.

**Decision:** Synthetix-style continuous accumulation.

**Consequences:**
- Pro: O(1) gas per claim — no iteration, no Merkle proofs
- Pro: Rewards accumulate continuously, not in batches
- Pro: Battle-tested pattern (used by Synthetix, Curve, Balancer)
- Con: `notifyRewardAmount` must be called manually each reward period
- Mitigation: REWARDS_MANAGER role held by the DAO Timelock, so new reward periods require a governance vote

---

## 9. Trust Assumptions

| Component | Trusted Party | Risk if compromised |
|-----------|--------------|---------------------|
| Chainlink price feeds | Chainlink oracle network | Stale or manipulated price blocks minting, not AMM pricing |
| Chainlink PoR feeds | Chainlink oracle network | False reserve data could allow over-issuance in V2 |
| DEPLOYER_PRIVATE_KEY | Deployer EOA | Full control before Timelock setup; zero risk after revoking admin |
| UPGRADER_ROLE holders | Timelock (post-governance) | Can upgrade implementations — requires passing governance vote |
| MINTER_ROLE holders | Timelock (post-governance) | Can print RWAGOV — requires governance vote |
| ONBOARDER_ROLE holders | Timelock (post-governance) | Can list new assets — requires governance vote |
| ISSUER_ROLE holders | Issuer company | Can issue/redeem RWAToken — regulated entity, KYC'd off-chain |
| REWARDS_MANAGER | DAO multisig | Can set reward rates — economic risk only, cannot steal funds |
| Off-chain collateral | Real-world asset custodian | Underlying asset not on-chain — enforced via PoR feed only |

**Trust minimization path:**
1. Deploy with deployer as admin (minimal trust window)
2. Deploy governance (Governor + Timelock)
3. Transfer UPGRADER_ROLE, MINTER_ROLE, ONBOARDER_ROLE to Timelock
4. Revoke deployer's DEFAULT_ADMIN_ROLE from all contracts
5. All future changes require a 1-day voting delay + 1-week vote + 2-day timelock = minimum 10 days

---

## 10. Network Deployment

The platform targets Ethereum L2 networks for lower gas costs.

**Arbitrum Sepolia:**
- Chain ID: 421614
- RPC: `https://sepolia-rollup.arbitrum.io/rpc`
- Explorer: `https://sepolia.arbiscan.io`
- Chainlink ETH/USD: `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165`

**Base Sepolia:**
- Chain ID: 84532
- RPC: `https://sepolia.base.org`
- Explorer: `https://sepolia.basescan.org`

Both networks are EVM-compatible and support `cancun` EVM version (required for `via_ir = true` compilation).

---

## 11. Off-Chain Components

### 11.1 CI/CD (GitHub Actions)

8-stage pipeline on every push/PR:

```
build → fmt-check → unit-tests → invariant-tests →
coverage → fork-tests (main only) → slither → deploy (main only)
```

### 11.2 The Graph Subgraph

Indexes all platform events for real-time querying:

**Static data sources:** RWAFactory, RWAPool, RWAStaking, RWAGovernor

**Dynamic templates:** RWAToken, RWAVault — created when `AssetOnboarded` fires, so every new asset instance is automatically indexed without redeploying the subgraph.

**Key entities:** Asset, Token, Vault, Pool, Swap, LiquidityEvent, StakingPosition, GovernanceProposal, Vote, Protocol (global stats)
