# RWA Tokenization Platform — Foundry + The Graph Makefile
# Usage: make <target>   (requires .env in project root)

-include .env
export

.PHONY: install build test test-fork coverage clean fmt \
        deploy-arbitrum deploy-base \
        deploy-l2-arbitrum deploy-l2-base \
        upgrade-arbitrum upgrade-base \
        deploy-governance-arbitrum deploy-governance-base \
        verify-arbitrum verify-base \
        subgraph-codegen subgraph-build subgraph-deploy \
        snapshot gas-report

# ── Dependencies ──────────────────────────────────────────────────────────────

install:
	forge install OpenZeppelin/openzeppelin-contracts --no-commit
	forge install OpenZeppelin/openzeppelin-contracts-upgradeable --no-commit
	forge install foundry-rs/forge-std --no-commit

# ── Build ─────────────────────────────────────────────────────────────────────

build:
	forge build --sizes

fmt:
	forge fmt

fmt-check:
	forge fmt --check

# ── Tests ─────────────────────────────────────────────────────────────────────

test:
	forge test --no-match-contract "ForkTest" -vvv

test-unit:
	forge test --no-match-contract "Invariant|ForkTest" -vvv

test-invariant:
	forge test --match-contract "Invariant" -vvv

test-fork:
	forge test --match-contract "ForkTest" \
		--fork-url $(ARBITRUM_SEPOLIA_RPC_URL) \
		-vvv

test-all:
	forge test -vvv

coverage:
	forge coverage \
		--no-match-contract "ForkTest" \
		--report lcov \
		--report summary

snapshot:
	forge snapshot --no-match-contract "ForkTest"

gas-report:
	forge test --no-match-contract "ForkTest" --gas-report

clean:
	forge clean

# ── Deploy — Participant 1 (core platform) ────────────────────────────────────

deploy-arbitrum:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(ARBITRUM_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		--delay 5 \
		-vvvv

deploy-base:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		--delay 5 \
		-vvvv

# ── Deploy — Participant 3 (combined L2 — single broadcast) ──────────────────

deploy-l2-arbitrum:
	forge script script/DeployL2.s.sol:DeployL2 \
		--rpc-url $(ARBITRUM_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ARBISCAN_API_KEY) \
		--delay 5 \
		-vvvv

deploy-l2-base:
	forge script script/DeployL2.s.sol:DeployL2 \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		--delay 5 \
		-vvvv

# ── Deploy — Participant 2 (governance) ───────────────────────────────────────

deploy-governance-arbitrum:
	forge script script/DeployGovernance.s.sol:DeployGovernance \
		--rpc-url $(ARBITRUM_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		--delay 5 \
		-vvvv

deploy-governance-base:
	forge script script/DeployGovernance.s.sol:DeployGovernance \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		--delay 5 \
		-vvvv

# ── Upgrade — V1 → V2 (add Proof-of-Reserve) ──────────────────────────────────

upgrade-arbitrum:
	forge script script/UpgradeRWAToken.s.sol:UpgradeRWAToken \
		--rpc-url $(ARBITRUM_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		--delay 5 \
		-vvvv

upgrade-base:
	forge script script/UpgradeRWAToken.s.sol:UpgradeRWAToken \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		--delay 5 \
		-vvvv

# ── Manual verification ───────────────────────────────────────────────────────

verify-arbitrum:
	forge verify-contract $(CONTRACT) $(CONTRACT_NAME) \
		--chain arbitrum-sepolia \
		--etherscan-api-key $(ARBISCAN_API_KEY)

verify-base:
	forge verify-contract $(CONTRACT) $(CONTRACT_NAME) \
		--chain base-sepolia \
		--etherscan-api-key $(BASESCAN_API_KEY)

# ── The Graph (Participant 3) ─────────────────────────────────────────────────

subgraph-codegen:
	cd subgraph && npm install && npm run codegen

subgraph-build:
	cd subgraph && npm run build

subgraph-deploy:
	cd subgraph && \
		graph auth --studio $(GRAPH_ACCESS_TOKEN) && \
		npm run deploy:studio

# ── Help ─────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "  RWA Tokenization Platform — Make targets"
	@echo ""
	@echo "  Build & Format:"
	@echo "    make build              forge build --sizes"
	@echo "    make fmt                forge fmt"
	@echo ""
	@echo "  Tests:"
	@echo "    make test               unit + fuzz tests"
	@echo "    make test-invariant     invariant tests"
	@echo "    make test-fork          fork tests (needs ARBITRUM_SEPOLIA_RPC_URL)"
	@echo "    make coverage           lcov + summary"
	@echo "    make gas-report         gas usage table"
	@echo ""
	@echo "  Deploy (requires .env):"
	@echo "    make deploy-l2-arbitrum        full platform (single broadcast) → Arbitrum Sepolia"
	@echo "    make deploy-arbitrum           core platform only → Arbitrum Sepolia"
	@echo "    make deploy-governance-arbitrum governance → Arbitrum Sepolia"
	@echo "    make upgrade-arbitrum           V1→V2 upgrade → Arbitrum Sepolia"
	@echo ""
	@echo "  The Graph:"
	@echo "    make subgraph-codegen   generate AssemblyScript types"
	@echo "    make subgraph-build     build subgraph WASM"
	@echo "    make subgraph-deploy    deploy to Graph Studio"
	@echo ""
