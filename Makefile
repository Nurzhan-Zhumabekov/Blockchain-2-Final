# Foundry convenience targets
# Usage: make install | make build | make test | make deploy-arbitrum

-include .env

.PHONY: install build test coverage clean deploy-arbitrum deploy-base verify-arbitrum verify-base

install:
	forge install OpenZeppelin/openzeppelin-contracts --no-commit
	forge install OpenZeppelin/openzeppelin-contracts-upgradeable --no-commit

build:
	forge build

test:
	forge test -vvv

coverage:
	forge coverage --report summary

clean:
	forge clean

deploy-arbitrum:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url arbitrum_sepolia \
		--broadcast \
		--verify \
		-vvvv

deploy-base:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url base_sepolia \
		--broadcast \
		--verify \
		-vvvv

verify-arbitrum:
	forge verify-contract $(CONTRACT) $(CONTRACT_NAME) \
		--chain arbitrum-sepolia \
		--etherscan-api-key $(ARBISCAN_API_KEY)

verify-base:
	forge verify-contract $(CONTRACT) $(CONTRACT_NAME) \
		--chain base-sepolia \
		--etherscan-api-key $(BASESCAN_API_KEY)
