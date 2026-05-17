# RWA Tokenization Platform

Blockchain Technologies 2 — Final Project (Option C)

This is our capstone project where we built a platform for tokenizing real-world assets (RWA) on Ethereum L2. The idea is simple: take a real asset like a US Treasury bond, issue an ERC-20 token that represents it, let people deposit those tokens into a yield vault, and trade them on an AMM — all governed by a DAO.

We deployed on Arbitrum Sepolia and Base Sepolia.

---

## Team

1. Nurzhan Zhumabekov — Core smart contracts (RWAToken, RWAFactory, RWAPool, GovernanceToken, RWAVault, AssetCertificate)
2. Abylay Abdykassymov — Governance (RWAGovernor, RWATimelock, upgrade path V1→V2 with Chainlink Proof-of-Reserve)
3. Abilkhaiyr Sarsenbay — Staking rewards, fork tests, CI/CD pipeline, The Graph subgraph, deployment infrastructure

---

## What we built

The platform has several pieces that work together:

**RWAToken** is the main ERC-20 token backed by a real-world asset. Only authorized issuers can mint it, and every mint checks that the Chainlink price feed is fresh (not older than 24 hours). In V2, minting also checks a Proof-of-Reserve feed so you can never mint more tokens than there is backing collateral.

**RWAFactory** deploys new asset instances using CREATE2 so the addresses are deterministic. Each asset gets its own RWAToken proxy, RWAVault proxy, and a soulbound NFT certificate minted to the issuer. The factory uses CREATE for the shared implementation contracts and CREATE2 for each proxy — we also wrote a Yul version of the CREATE2 address prediction and benchmarked it against the Solidity version.

**RWAVault** is an ERC-4626 tokenized vault. You deposit RWATokens and get vault shares back. The manager can deposit real-world yield which increases the share value for everyone — so later depositors don't get yield they didn't earn.

**RWAPool** is a constant-product AMM (x·y = k) for swapping RWAGOV ↔ RWAToken with a 0.3% fee. LP shares are minted as an ERC-20. The `getAmountOut` function is implemented in Yul assembly and benchmarked against the equivalent Solidity version.

**GovernanceToken (RWAGOV)** is an ERC-20Votes + ERC-20Permit upgradeable token. The DAO uses it to vote on proposals.

**RWAGovernor + RWATimelock** are the DAO governance contracts. Proposals need 1000 RWAGOV to create, 1-day voting delay, 1-week voting period, 4% quorum, and a 2-day timelock before execution.

**AssetCertificate** is a soulbound ERC-721 NFT. Every onboarded asset gets one minted to the issuer. It's non-transferable — if you try to transfer it, it reverts.

**RWAStaking** lets RWAGOV holders stake and earn RWAToken rewards distributed by the DAO. Standard Synthetix-style reward accumulation — rewards are proportional to your stake and time.

---

## Technical highlights

- **UUPS proxy pattern** — all main contracts are upgradeable. V2 adds Chainlink Proof-of-Reserve to RWAToken without changing the proxy address.
- **Inline Yul assembly** — used in `getAmountOut()` (AMM), `_sqrt()` (Babylonian, for LP minting), and `predictProxyAddress()` (CREATE2 prediction). Each has a Solidity equivalent for gas comparison.
- **Chainlink price feeds** — staleness checks on both the price feed (24h threshold for RWAToken) and the AMM (1h threshold for RWAPool).
- **ERC-4626** — vault follows the standard completely, rounding invariants included.
- **CREATE + CREATE2** — factory uses CREATE for implementations (in constructor), CREATE2 for deterministic proxy deployment per asset.
- **Fork tests** — test against real Chainlink feeds on Arbitrum Sepolia.
- **The Graph** — subgraph indexes all platform events (issues, redeems, swaps, liquidity, staking, governance votes).

---

## Project structure

```
src/
  GovernanceToken.sol     ERC-20Votes + ERC-20Permit + UUPS
  RWAToken.sol            Asset-backed ERC-20 + Chainlink feed
  RWATokenV2.sol          V2 upgrade: adds Proof-of-Reserve
  AssetCertificate.sol    Soulbound ERC-721 certificate
  RWAVault.sol            ERC-4626 yield vault
  RWAFactory.sol          CREATE + CREATE2 factory
  RWAPool.sol             x*y=k AMM with Yul
  RWAGovernor.sol         OZ Governor stack
  RWATimelock.sol         TimelockController
  RWAStaking.sol          Synthetix-style staking rewards

script/
  DeployL2.s.sol          Combined L2 deployment (all contracts, single broadcast)
  Deploy.s.sol            Deploy core platform only
  DeployGovernance.s.sol  Deploy Governor + Timelock only
  DeployStaking.s.sol     Deploy staking contract only
  UpgradeRWAToken.s.sol   Upgrade V1 -> V2
  Verify.s.sol            Post-deployment role verification

test/
  RWAToken.t.sol          25 tests (unit + fuzz + upgrade)
  RWAPool.t.sol           19 tests (AMM + k-invariant fuzz)
  RWAFactory.t.sol        18 tests (CREATE2 + soulbound NFT)
  RWAVault.t.sol          17 tests (ERC-4626 + yield)
  RWAGovernor.t.sol       14 tests (full proposal lifecycle)
  RWAStaking.t.sol        27 tests (stake + rewards + fuzz)
  Invariant.t.sol         5 invariant tests (pool + vault)
  Fork.t.sol              Fork tests (Arbitrum Sepolia)

subgraph/
  schema.graphql          GraphQL entities
  subgraph.yaml           Manifest for Arbitrum Sepolia
  src/rwa-platform.ts     AssemblyScript event mappings

.github/workflows/
  ci.yml                  CI: build → test → coverage → slither → deploy
```

---

## How to run

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git

### Install dependencies

```bash
git clone https://github.com/Nurzhan-Zhumabekov/Blockchain-2-Final
cd Blockchain-2-Final
forge install
```

### Build

```bash
forge build
# or
make build
```

### Run tests

```bash
# All unit + fuzz tests
forge test --no-match-contract "ForkTest"

# With gas report
forge test --no-match-contract "ForkTest" --gas-report

# Invariant tests
forge test --match-contract "Invariant"

# Fork tests (need RPC URL)
forge test --match-contract "ForkTest" --fork-url $ARBITRUM_SEPOLIA_RPC_URL
```

### Coverage

```bash
forge coverage --no-match-contract "ForkTest" --report summary
```

---

## Deployment

Copy `.env.example` to `.env` and fill in your keys.

```bash
cp .env.example .env
```

```bash
# Option A: Combined deployment (recommended) — deploys everything in one broadcast
make deploy-l2-arbitrum

# Option B: Step-by-step deployment
# 1. Deploy core platform
make deploy-arbitrum

# 2. Deploy governance (set GOV_TOKEN_PROXY from step 1)
make deploy-governance-arbitrum

# 3. Upgrade RWAToken to V2 with Proof-of-Reserve (set RWA_TOKEN_PROXY + RESERVE_FEED_ADDRESS)
make upgrade-arbitrum

# 4. Deploy staking (set GOV_TOKEN_PROXY + RWA_TOKEN_PROXY)
forge script script/DeployStaking.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast --verify

# 5. Verify post-deployment wiring (no broadcast needed)
forge script script/Verify.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --env-file .env.deployed
```

### Deployed addresses (Arbitrum Sepolia)

| Contract | Address |
|----------|---------|
| GovernanceToken (proxy) | TBD |
| RWAFactory | TBD |
| RWAToken USTB (proxy) | TBD |
| RWAVault (proxy) | TBD |
| RWAPool | TBD |
| RWAGovernor | TBD |
| RWATimelock | TBD |
| RWAStaking | TBD |

---

## The Graph

After deploying, update contract addresses in `subgraph/subgraph.yaml`, then:

```bash
cd subgraph
npm install
npm run codegen
npm run build
npm run deploy:studio
```

---

## Dependencies

- [Foundry](https://github.com/foundry-rs/foundry) — build, test, deploy
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) v5
- [OpenZeppelin Contracts Upgradeable](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) v5
- [Chainlink](https://docs.chain.link/) — price feeds + Proof of Reserve
- [The Graph](https://thegraph.com/) — on-chain data indexing
