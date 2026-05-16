# Foundry convenience targets
# Usage: make install | make build | make test

-include .env

.PHONY: install build test clean

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
