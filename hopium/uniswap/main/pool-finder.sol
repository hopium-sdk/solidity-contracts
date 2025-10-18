// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/uniswap/types/pool.sol";
import "hopium/common/interface/imDirectory.sol";
import "hopium/uniswap/interface/imUniswapOracle.sol";

error TokenIsWETH();
error ZeroAddress();

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
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

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

abstract contract Storage {
    mapping(address => Pool) internal cachedPools;

    event PoolChanged(address poolAddress, bool isV3Pool, address t0, address t1, uint8 d0, uint8 d1);
}

abstract contract Helpers is Storage, ImUniswapOracle {

    function _getPoolTokens(address poolAddress, bool isV3Pool) internal view returns (address t0, address t1, uint8 d0, uint8 d1) {
        if (isV3Pool) {
            t0 = IUniswapV3Pool(poolAddress).token0();
            t1 = IUniswapV3Pool(poolAddress).token1();
        } else {
            t0 = IUniswapV2Pair(poolAddress).token0();
            t1 = IUniswapV2Pair(poolAddress).token1();
        }
        d0 = IERC20Metadata(t0).decimals();
        d1 = IERC20Metadata(t1).decimals();
    }

    function _emitPoolChangedEvent(Pool memory pool) internal {
        (address t0, address t1, uint8 d0, uint8 d1) = _getPoolTokens(pool.poolAddress, pool.isV3Pool == 1);
        emit PoolChanged(pool.poolAddress, pool.isV3Pool == 1, t0, t1, d0, d1); 
    }

    function emitPoolChangedEventOnWethUsdPool(address poolAddress, bool isV3Pool) external onlyUniswapOracle {
        (address t0, address t1, uint8 d0, uint8 d1) = _getPoolTokens(poolAddress, isV3Pool);
        emit PoolChanged(poolAddress, isV3Pool, t0, t1, d0, d1); 
    }
}

contract PoolFinder is ImDirectory, Helpers {
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


    // constant fee tiers — cheapest way (no constructor needed)
    uint24 internal constant V3_FEE0 = 3000;   // 0.3%
    uint24 internal constant V3_FEE1 = 10000;  // 1%
    uint256 internal constant V3_FEE_COUNT = 2;

    uint256 public staleTime = 6 hours;

    function findBestWethPool(address tokenAddress) public view returns (Pool memory pool) {
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
        return findBestWethPool(tokenAddress);
    }

    // ---- WRITE fn: populate if missing; refresh only when stale; else return cached
    function getBestWethPoolAndUpdateIfStale(address tokenAddress) public returns (Pool memory out) {
        Pool storage slot = cachedPools[tokenAddress];

        // missing?
        if (slot.poolAddress == address(0)) {
            out = findBestWethPool(tokenAddress);
            cachedPools[tokenAddress] = out; // <-- fix
            _emitPoolChangedEvent(out);
            return out;
        }

        // stale?
        if (block.timestamp - slot.lastCached > staleTime) {
            Pool memory fresh = findBestWethPool(tokenAddress);
            if (fresh.poolAddress != slot.poolAddress) {
                cachedPools[tokenAddress] = fresh; // <-- fix
                _emitPoolChangedEvent(fresh);
                return fresh;
            } else {
                slot.lastCached = uint64(block.timestamp); // ok to update a single field
            }
        }

        // fresh cache
        out = slot;
    }

    // ---- WRITE fn: force update cache
    function getBestWethPoolAndForceUpdate(address tokenAddress) public returns (Pool memory out) {
        out = findBestWethPool(tokenAddress);
        cachedPools[tokenAddress] = out;
        _emitPoolChangedEvent(out);
    }

    function setStaleTimePoolCache(uint256 newStaleTime) external onlyOwner {
        staleTime = newStaleTime;
    }
}