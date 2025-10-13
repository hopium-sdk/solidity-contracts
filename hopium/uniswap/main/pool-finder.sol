// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/uniswap/types/pool.sol";
import "hopium/common/interface/imDirectory.sol";

error TokenIsWETH();
error ZeroAddress();

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 t);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

contract PoolFinder is ImDirectory {
    address public immutable wethAddress;
    IUniswapV2Factory public immutable v2Factory;
    IUniswapV3Factory public immutable v3Factory;

    constructor(
        address _directory,
        address _wethAddress,
        address _v2Factory,
        address _v3Factory
        ) ImDirectory(_directory) {
            if (_wethAddress == address(0)) revert ZeroAddress();
            if (_v2Factory  == address(0)) revert ZeroAddress();
            if (_v3Factory == address(0)) revert ZeroAddress();

            wethAddress = _wethAddress;
            v2Factory = IUniswapV2Factory(_v2Factory);
            v3Factory = IUniswapV3Factory(_v3Factory);
        }

    mapping(address => Pool) internal cachedPools;

    // constant fee tiers — cheapest way (no constructor needed)
    uint24 internal constant V3_FEE0 = 3000;   // 0.3%
    uint24 internal constant V3_FEE1 = 10000;  // 1%
    uint256 internal constant V3_FEE_COUNT = 2;

    uint256 public staleTime = 6 hours;

    // ---- internal pool finder (pure read logic)
    function _findBestWethPool(address tokenAddress) internal view returns (Pool memory pool) {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (tokenAddress == wethAddress) revert TokenIsWETH();

        address _weth = wethAddress;
        IERC20 Weth = IERC20(_weth);
        uint256 poolWethLiquidity;

        // --- Uniswap V2 ---
        address v2Pair = v2Factory.getPair(tokenAddress, _weth);
        if (v2Pair != address(0)) {
            (uint112 r0, uint112 r1, ) = IUniswapV2Pair(v2Pair).getReserves();
            address t0 = IUniswapV2Pair(v2Pair).token0();
            uint256 w = (t0 == _weth) ? uint256(r0) : uint256(r1);
            if (w > poolWethLiquidity) {
                pool.isV3Pool = 0;
                pool.poolAddress = v2Pair;
                pool.poolFee = 0;
                poolWethLiquidity = w;
            }
        }

        // --- Uniswap V3 --- (iterate with unchecked)
        for (uint256 i; i < V3_FEE_COUNT; ) {
            // emulate constant array indexing
            uint24 fee = (i == 0) ? V3_FEE0 : V3_FEE1;

            address p = v3Factory.getPool(tokenAddress, _weth, fee);
            if (p != address(0)) {
                uint256 w = Weth.balanceOf(p);
                if (w > poolWethLiquidity) {
                    pool.isV3Pool = 1;
                    pool.poolAddress = p;
                    pool.poolFee = fee;
                    poolWethLiquidity = w;
                }
            }
            unchecked { ++i; }
        }

        pool.lastCached = uint64(block.timestamp);
    }

    // ---- READ fn: hit -> return cache; miss -> compute (no writes)
    function getBestWethPool(address tokenAddress) external view returns (Pool memory pool) {
        pool = cachedPools[tokenAddress];
        if (pool.poolAddress != address(0)) return pool;
        return _findBestWethPool(tokenAddress);
    }

    // ---- WRITE fn: populate if missing; refresh only when stale; else return cached
    function getBestWethPoolUpdatable(address tokenAddress) public returns (Pool memory out) {
        Pool storage slot = cachedPools[tokenAddress];

        // missing?
        if (slot.poolAddress == address(0)) {
            out = _findBestWethPool(tokenAddress);
            cachedPools[tokenAddress] = out; // <-- fix
            return out;
        }

        // stale?
        if (block.timestamp - slot.lastCached > staleTime) {
            Pool memory fresh = _findBestWethPool(tokenAddress);
            if (fresh.poolAddress != slot.poolAddress) {
                cachedPools[tokenAddress] = fresh; // <-- fix
                return fresh;
            } else {
                slot.lastCached = uint64(block.timestamp); // ok to update a single field
            }
        }

        // fresh cache
        out = slot;
    }

    function setStaleTimePoolCache(uint256 newStaleTime) external onlyOwner {
        staleTime = newStaleTime;
    }
}