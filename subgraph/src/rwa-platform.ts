import {
  Address,
  BigDecimal,
  BigInt,
  Bytes,
  crypto,
  ethereum,
  log,
} from "@graphprotocol/graph-ts";

import {
  AssetOnboarded,
} from "../../generated/RWAFactory/RWAFactory";

import {
  Swap as SwapEvent,
  LiquidityAdded,
  LiquidityRemoved,
} from "../../generated/RWAPool/RWAPool";

import {
  Staked,
  Withdrawn,
  RewardPaid,
  RewardAdded,
} from "../../generated/RWAStaking/RWAStaking";

import {
  ProposalCreated,
  VoteCast,
  ProposalExecuted,
  ProposalCanceled,
} from "../../generated/RWAGovernor/RWAGovernor";

import {
  Issued,
  Redeemed,
} from "../../generated/templates/RWAToken/RWAToken";

import {
  YieldDeposited,
} from "../../generated/templates/RWAVault/RWAVault";

import {
  RWAToken as RWATokenTemplate,
  RWAVault as RWAVaultTemplate,
} from "../../generated/templates";

import {
  Asset,
  Certificate,
  Token,
  Vault,
  IssueEvent,
  RedeemEvent,
  Pool,
  Swap,
  LiquidityEvent,
  StakingPool,
  StakingPosition,
  StakeEvent,
  GovernanceProposal,
  Vote,
  Protocol,
  YieldDeposit,
} from "../../generated/schema";

// ─── Helpers ──────────────────────────────────────────────────────────────────

const DECIMALS = BigDecimal.fromString("1000000000000000000"); // 1e18
const ZERO_BD  = BigDecimal.fromString("0");
const ONE_BI   = BigInt.fromI32(1);

function toDecimal(raw: BigInt): BigDecimal {
  return raw.toBigDecimal().div(DECIMALS);
}

function getOrCreateProtocol(): Protocol {
  let protocol = Protocol.load("rwa-platform");
  if (protocol == null) {
    protocol = new Protocol("rwa-platform");
    protocol.totalAssets     = 0;
    protocol.totalIssued     = ZERO_BD;
    protocol.totalRedeemed   = ZERO_BD;
    protocol.totalSwapVolume = ZERO_BD;
    protocol.totalYield      = ZERO_BD;
  }
  return protocol as Protocol;
}

function getOrCreatePool(address: Address): Pool {
  let pool = Pool.load(address);
  if (pool == null) {
    pool = new Pool(address);
    pool.token0       = Bytes.empty();
    pool.token1       = Bytes.empty();
    pool.reserve0     = ZERO_BD;
    pool.reserve1     = ZERO_BD;
    pool.totalLPSupply = ZERO_BD;
  }
  return pool as Pool;
}

function getOrCreateStakingPool(address: Address): StakingPool {
  let sp = StakingPool.load(address);
  if (sp == null) {
    sp = new StakingPool(address);
    sp.totalStaked  = ZERO_BD;
    sp.rewardRate   = ZERO_BD;
    sp.periodFinish = BigInt.fromI32(0);
  }
  return sp as StakingPool;
}

function getOrCreateStakingPosition(pool: StakingPool, staker: Address): StakingPosition {
  let id = pool.id.toHexString() + "-" + staker.toHexString();
  let pos = StakingPosition.load(Bytes.fromUTF8(id));
  if (pos == null) {
    pos = new StakingPosition(Bytes.fromUTF8(id));
    pos.pool           = pool.id;
    pos.staker         = staker;
    pos.stakedAmount   = ZERO_BD;
    pos.rewardsClaimed = ZERO_BD;
    pos.lastUpdated    = BigInt.fromI32(0);
  }
  return pos as StakingPosition;
}

// ─── RWAFactory handlers ──────────────────────────────────────────────────────

export function handleAssetOnboarded(event: AssetOnboarded): void {
  let saltHex = event.params.salt.toHexString();

  // Token entity
  let token = new Token(event.params.tokenProxy);
  token.name            = "";
  token.symbol          = "";
  token.assetType       = "";
  token.totalSupply     = ZERO_BD;
  token.totalCollateral = ZERO_BD;
  token.priceFeed       = Bytes.empty();
  token.save();

  // Vault entity
  let vault = new Vault(event.params.vaultProxy);
  vault.totalYieldAccrued = ZERO_BD;
  vault.save();

  // Asset entity
  let asset = new Asset(event.params.salt);
  asset.tokenProxy    = event.params.tokenProxy;
  asset.vaultProxy    = event.params.vaultProxy;
  asset.issuer        = event.params.issuer;
  asset.assetType     = "";
  asset.certificateId = event.params.certificateId;
  asset.deployedAt    = event.block.timestamp;
  asset.token         = token.id;
  asset.vault         = vault.id;
  asset.save();

  // Start indexing dynamic contract instances
  RWATokenTemplate.create(Address.fromBytes(event.params.tokenProxy));
  RWAVaultTemplate.create(Address.fromBytes(event.params.vaultProxy));

  // Update global stats
  let protocol = getOrCreateProtocol();
  protocol.totalAssets = protocol.totalAssets + 1;
  protocol.save();

  log.info("Asset onboarded: tokenProxy={}, vaultProxy={}", [
    event.params.tokenProxy.toHexString(),
    event.params.vaultProxy.toHexString(),
  ]);
}

// ─── RWAToken handlers ────────────────────────────────────────────────────────

export function handleIssued(event: Issued): void {
  let tokenAddr = event.address;
  let token = Token.load(tokenAddr);
  if (token == null) return;

  let amount = toDecimal(event.params.amount);
  token.totalSupply = token.totalSupply.plus(amount);
  token.save();

  // IssueEvent
  let ev = new IssueEvent(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  );
  ev.token       = token.id;
  ev.issuer      = event.params.issuer;
  ev.to          = event.params.to;
  ev.amount      = amount;
  ev.blockNumber = event.block.number;
  ev.timestamp   = event.block.timestamp;
  ev.txHash      = event.transaction.hash;
  ev.save();

  let protocol = getOrCreateProtocol();
  protocol.totalIssued = protocol.totalIssued.plus(amount);
  protocol.save();
}

export function handleRedeemed(event: Redeemed): void {
  let tokenAddr = event.address;
  let token = Token.load(tokenAddr);
  if (token == null) return;

  let amount = toDecimal(event.params.amount);
  token.totalSupply = token.totalSupply.minus(amount);
  if (token.totalSupply.lt(ZERO_BD)) token.totalSupply = ZERO_BD;
  token.save();

  let ev = new RedeemEvent(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  );
  ev.token       = token.id;
  ev.from        = event.params.from;
  ev.amount      = amount;
  ev.blockNumber = event.block.number;
  ev.timestamp   = event.block.timestamp;
  ev.txHash      = event.transaction.hash;
  ev.save();

  let protocol = getOrCreateProtocol();
  protocol.totalRedeemed = protocol.totalRedeemed.plus(amount);
  protocol.save();
}

// ─── RWAVault handlers ────────────────────────────────────────────────────────

export function handleYieldDeposited(event: YieldDeposited): void {
  let vault = Vault.load(event.address);
  if (vault == null) return;

  let amount = toDecimal(event.params.amount);
  vault.totalYieldAccrued = vault.totalYieldAccrued.plus(amount);
  vault.save();

  let ev = new YieldDeposit(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  );
  ev.vault       = vault.id;
  ev.source      = event.params.source;
  ev.amount      = amount;
  ev.blockNumber = event.block.number;
  ev.timestamp   = event.block.timestamp;
  ev.txHash      = event.transaction.hash;
  ev.save();

  let protocol = getOrCreateProtocol();
  protocol.totalYield = protocol.totalYield.plus(amount);
  protocol.save();
}

// ─── RWAPool handlers ─────────────────────────────────────────────────────────

export function handleSwap(event: SwapEvent): void {
  let pool = getOrCreatePool(event.address);

  let amountIn  = toDecimal(event.params.amountIn);
  let amountOut = toDecimal(event.params.amountOut);

  let ev = new Swap(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  );
  ev.pool        = pool.id;
  ev.trader      = event.params.trader;
  ev.tokenIn     = event.params.tokenIn;
  ev.amountIn    = amountIn;
  ev.amountOut   = amountOut;
  ev.blockNumber = event.block.number;
  ev.timestamp   = event.block.timestamp;
  ev.txHash      = event.transaction.hash;
  ev.save();

  pool.save();

  let protocol = getOrCreateProtocol();
  protocol.totalSwapVolume = protocol.totalSwapVolume.plus(amountIn);
  protocol.save();
}

export function handleLiquidityAdded(event: LiquidityAdded): void {
  let pool = getOrCreatePool(event.address);
  pool.totalLPSupply = pool.totalLPSupply.plus(toDecimal(event.params.shares));
  pool.reserve0      = pool.reserve0.plus(toDecimal(event.params.amount0));
  pool.reserve1      = pool.reserve1.plus(toDecimal(event.params.amount1));
  pool.save();

  let ev = new LiquidityEvent(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  );
  ev.pool        = pool.id;
  ev.provider    = event.params.provider;
  ev.type        = "ADD";
  ev.amount0     = toDecimal(event.params.amount0);
  ev.amount1     = toDecimal(event.params.amount1);
  ev.shares      = toDecimal(event.params.shares);
  ev.blockNumber = event.block.number;
  ev.timestamp   = event.block.timestamp;
  ev.txHash      = event.transaction.hash;
  ev.save();
}

export function handleLiquidityRemoved(event: LiquidityRemoved): void {
  let pool = getOrCreatePool(event.address);
  pool.totalLPSupply = pool.totalLPSupply.minus(toDecimal(event.params.shares));
  pool.reserve0      = pool.reserve0.minus(toDecimal(event.params.amount0));
  pool.reserve1      = pool.reserve1.minus(toDecimal(event.params.amount1));
  if (pool.reserve0.lt(ZERO_BD)) pool.reserve0 = ZERO_BD;
  if (pool.reserve1.lt(ZERO_BD)) pool.reserve1 = ZERO_BD;
  pool.save();

  let ev = new LiquidityEvent(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  );
  ev.pool        = pool.id;
  ev.provider    = event.params.provider;
  ev.type        = "REMOVE";
  ev.amount0     = toDecimal(event.params.amount0);
  ev.amount1     = toDecimal(event.params.amount1);
  ev.shares      = toDecimal(event.params.shares);
  ev.blockNumber = event.block.number;
  ev.timestamp   = event.block.timestamp;
  ev.txHash      = event.transaction.hash;
  ev.save();
}

// ─── RWAStaking handlers ─────────────────────────────────────────────────────

export function handleStaked(event: Staked): void {
  let sp  = getOrCreateStakingPool(event.address);
  let pos = getOrCreateStakingPosition(sp, event.params.user);

  let amount = toDecimal(event.params.amount);
  sp.totalStaked       = sp.totalStaked.plus(amount);
  pos.stakedAmount     = pos.stakedAmount.plus(amount);
  pos.lastUpdated      = event.block.timestamp;
  sp.save();
  pos.save();

  let ev = new StakeEvent(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  );
  ev.pool        = sp.id;
  ev.user        = event.params.user;
  ev.amount      = amount;
  ev.type        = "STAKE";
  ev.blockNumber = event.block.number;
  ev.timestamp   = event.block.timestamp;
  ev.txHash      = event.transaction.hash;
  ev.save();
}

export function handleWithdrawn(event: Withdrawn): void {
  let sp  = getOrCreateStakingPool(event.address);
  let pos = getOrCreateStakingPosition(sp, event.params.user);

  let amount = toDecimal(event.params.amount);
  sp.totalStaked   = sp.totalStaked.minus(amount);
  pos.stakedAmount = pos.stakedAmount.minus(amount);
  if (pos.stakedAmount.lt(ZERO_BD)) pos.stakedAmount = ZERO_BD;
  pos.lastUpdated  = event.block.timestamp;
  sp.save();
  pos.save();

  let ev = new StakeEvent(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  );
  ev.pool        = sp.id;
  ev.user        = event.params.user;
  ev.amount      = amount;
  ev.type        = "WITHDRAW";
  ev.blockNumber = event.block.number;
  ev.timestamp   = event.block.timestamp;
  ev.txHash      = event.transaction.hash;
  ev.save();
}

export function handleRewardPaid(event: RewardPaid): void {
  let sp  = getOrCreateStakingPool(event.address);
  let pos = getOrCreateStakingPosition(sp, event.params.user);

  let amount = toDecimal(event.params.reward);
  pos.rewardsClaimed = pos.rewardsClaimed.plus(amount);
  pos.lastUpdated    = event.block.timestamp;
  pos.save();

  let ev = new StakeEvent(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  );
  ev.pool        = sp.id;
  ev.user        = event.params.user;
  ev.amount      = amount;
  ev.type        = "CLAIM";
  ev.blockNumber = event.block.number;
  ev.timestamp   = event.block.timestamp;
  ev.txHash      = event.transaction.hash;
  ev.save();
}

export function handleRewardAdded(event: RewardAdded): void {
  let sp = getOrCreateStakingPool(event.address);
  sp.rewardRate   = toDecimal(event.params.newRate);
  sp.periodFinish = event.params.periodFinish;
  sp.save();
}

// ─── RWAGovernor handlers ─────────────────────────────────────────────────────

export function handleProposalCreated(event: ProposalCreated): void {
  let proposal = new GovernanceProposal(event.params.proposalId);
  proposal.proposer     = event.params.proposer;
  proposal.description  = event.params.description;
  proposal.state        = "Pending";
  proposal.forVotes     = ZERO_BD;
  proposal.againstVotes = ZERO_BD;
  proposal.abstainVotes = ZERO_BD;
  proposal.startBlock   = event.params.voteStart;
  proposal.endBlock     = event.params.voteEnd;
  proposal.createdAt    = event.block.timestamp;
  proposal.executedAt   = null;
  proposal.save();
}

export function handleVoteCast(event: VoteCast): void {
  let proposal = GovernanceProposal.load(event.params.proposalId);
  if (proposal == null) return;

  let weight = toDecimal(event.params.weight);
  if (event.params.support == 0) {
    proposal.againstVotes = proposal.againstVotes.plus(weight);
  } else if (event.params.support == 1) {
    proposal.forVotes = proposal.forVotes.plus(weight);
  } else {
    proposal.abstainVotes = proposal.abstainVotes.plus(weight);
  }
  proposal.state = "Active";
  proposal.save();

  let v = new Vote(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  );
  v.proposal    = proposal.id;
  v.voter       = event.params.voter;
  v.support     = event.params.support;
  v.weight      = weight;
  v.blockNumber = event.block.number;
  v.timestamp   = event.block.timestamp;
  v.txHash      = event.transaction.hash;
  v.save();
}

export function handleProposalExecuted(event: ProposalExecuted): void {
  let proposal = GovernanceProposal.load(event.params.proposalId);
  if (proposal == null) return;
  proposal.state      = "Executed";
  proposal.executedAt = event.block.timestamp;
  proposal.save();
}

export function handleProposalCanceled(event: ProposalCanceled): void {
  let proposal = GovernanceProposal.load(event.params.proposalId);
  if (proposal == null) return;
  proposal.state = "Canceled";
  proposal.save();
}
