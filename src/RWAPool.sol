// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20}           from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable}        from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

// Constant-product AMM (x * y = k) for RWAGOV ↔ RWAToken liquidity.
// 0.3% fee; LP shares minted as RWAP ERC-20; slippage protection on every swap.
// getAmountOut() implemented in Yul — benchmarked against getAmountOutSolidity().
contract RWAPool is ERC20, ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20                public immutable token0;   // RWAGOV
    IERC20                public immutable token1;   // RWAToken
    AggregatorV3Interface public immutable priceFeed;

    uint256 public constant FEE_NUMERATOR     = 3;
    uint256 public constant FEE_DENOMINATOR   = 1000;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 public constant STALENESS_THRESHOLD = 1 hours;

    uint256 public reserve0;
    uint256 public reserve1;

    error InsufficientLiquidity();
    error InsufficientOutputAmount();
    error SlippageExceeded(uint256 got, uint256 min);
    error StalePrice(uint256 updatedAt);
    error ZeroAmount();
    error ZeroAddress();
    error InvalidToken();
    error SelfSwapNotAllowed();

    event LiquidityAdded  (address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event Swap            (address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    constructor(
        address _token0,
        address _token1,
        address _priceFeed,
        address admin
    ) ERC20("RWA-Pool LP", "RWAP") {
        if (_token0 == address(0) || _token1 == address(0) || admin == address(0)) revert ZeroAddress();
        token0    = IERC20(_token0);
        token1    = IERC20(_token1);
        priceFeed = AggregatorV3Interface(_priceFeed);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE,        admin);
    }

    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant whenNotPaused returns (uint256 liquidity) {
        if (amount0Desired == 0 || amount1Desired == 0) revert ZeroAmount();
        _checkFeed();

        uint256 amount0;
        uint256 amount1;

        if (reserve0 == 0 && reserve1 == 0) {
            amount0 = amount0Desired;
            amount1 = amount1Desired;
        } else {
            uint256 amount1Optimal = (amount0Desired * reserve1) / reserve0;
            if (amount1Optimal <= amount1Desired) {
                if (amount1Optimal < amount1Min) revert SlippageExceeded(amount1Optimal, amount1Min);
                amount0 = amount0Desired;
                amount1 = amount1Optimal;
            } else {
                uint256 amount0Optimal = (amount1Desired * reserve0) / reserve1;
                if (amount0Optimal < amount0Min) revert SlippageExceeded(amount0Optimal, amount0Min);
                amount0 = amount0Optimal;
                amount1 = amount1Desired;
            }
        }

        uint256 supply = totalSupply();
        if (supply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(1), MINIMUM_LIQUIDITY);
        } else {
            uint256 s0 = (amount0 * supply) / reserve0;
            uint256 s1 = (amount1 * supply) / reserve1;
            liquidity  = s0 < s1 ? s0 : s1;
        }

        if (liquidity == 0) revert InsufficientLiquidity();

        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);
        reserve0 += amount0;
        reserve1 += amount1;

        _mint(msg.sender, liquidity);
        emit LiquidityAdded(msg.sender, amount0, amount1, liquidity);
    }

    function removeLiquidity(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant whenNotPaused returns (uint256 amount0, uint256 amount1) {
        if (shares == 0) revert ZeroAmount();

        uint256 supply = totalSupply();
        amount0 = (shares * reserve0) / supply;
        amount1 = (shares * reserve1) / supply;

        if (amount0 < amount0Min) revert SlippageExceeded(amount0, amount0Min);
        if (amount1 < amount1Min) revert SlippageExceeded(amount1, amount1Min);

        _burn(msg.sender, shares);
        reserve0 -= amount0;
        reserve1 -= amount1;

        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);
        emit LiquidityRemoved(msg.sender, amount0, amount1, shares);
    }

    function swap(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (msg.sender == address(this)) revert SelfSwapNotAllowed();
        if (tokenIn != address(token0) && tokenIn != address(token1)) revert InvalidToken();
        if (amountIn == 0) revert ZeroAmount();
        _checkFeed();

        bool isToken0 = tokenIn == address(token0);
        (IERC20 inputToken, IERC20 outputToken, uint256 resIn, uint256 resOut) =
            isToken0
                ? (token0, token1, reserve0, reserve1)
                : (token1, token0, reserve1, reserve0);

        inputToken.safeTransferFrom(msg.sender, address(this), amountIn);

        amountOut = getAmountOut(amountIn, resIn, resOut);
        if (amountOut == 0)            revert InsufficientOutputAmount();
        if (amountOut < amountOutMin)  revert SlippageExceeded(amountOut, amountOutMin);

        outputToken.safeTransfer(msg.sender, amountOut);

        if (isToken0) { reserve0 += amountIn; reserve1 -= amountOut; }
        else          { reserve1 += amountIn; reserve0 -= amountOut; }

        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
    }

    // Yul implementation — benchmarked against getAmountOutSolidity below.
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

    // Pure-Solidity equivalent — used in gas benchmarks to quantify Yul savings.
    function getAmountOutSolidity(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public pure returns (uint256)
    {
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - FEE_NUMERATOR);
        return (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    function _checkFeed() internal view {
        if (address(priceFeed) == address(0)) return;
        (, , , uint256 updatedAt, ) = priceFeed.latestRoundData();
        if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert StalePrice(updatedAt);
    }

    // Babylonian square root in Yul — for initial LP minting.
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

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
}
