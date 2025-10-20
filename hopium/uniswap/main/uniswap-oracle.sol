// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/uniswap/interface/imPoolFinder.sol";
import "hopium/common/lib/full-math.sol";

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}


abstract contract Storage {
    address public immutable WETH_ADDRESS;
    address public immutable USD_ADDRESS;
    address public immutable WETH_USD_PAIR_ADDRESS;
    bool public immutable IS_WETH_USD_PAIR_ADDRESS_V3;

    uint8 public immutable WETH_DECIMALS;
}

abstract contract POW {
    uint256 constant WAD = 1e18;

    // Cheap powers of 10 (0..18). Using a lookup table is much cheaper than 10 ** x.
    uint256 private constant POW10_0  = 1;
    uint256 private constant POW10_1  = 10;
    uint256 private constant POW10_2  = 100;
    uint256 private constant POW10_3  = 1_000;
    uint256 private constant POW10_4  = 10_000;
    uint256 private constant POW10_5  = 100_000;
    uint256 private constant POW10_6  = 1_000_000;
    uint256 private constant POW10_7  = 10_000_000;
    uint256 private constant POW10_8  = 100_000_000;
    uint256 private constant POW10_9  = 1_000_000_000;
    uint256 private constant POW10_10 = 10_000_000_000;
    uint256 private constant POW10_11 = 100_000_000_000;
    uint256 private constant POW10_12 = 1_000_000_000_000;
    uint256 private constant POW10_13 = 10_000_000_000_000;
    uint256 private constant POW10_14 = 100_000_000_000_000;
    uint256 private constant POW10_15 = 1_000_000_000_000_000;
    uint256 private constant POW10_16 = 10_000_000_000_000_000;
    uint256 private constant POW10_17 = 100_000_000_000_000_000;
    uint256 private constant POW10_18 = 1_000_000_000_000_000_000;

    /// Fast 10^n for 0 <= n <= 18 using constants above.
    function _pow10(uint8 n) internal pure returns (uint256) {
        if (n == 0)  return POW10_0;
        if (n == 1)  return POW10_1;
        if (n == 2)  return POW10_2;
        if (n == 3)  return POW10_3;
        if (n == 4)  return POW10_4;
        if (n == 5)  return POW10_5;
        if (n == 6)  return POW10_6;
        if (n == 7)  return POW10_7;
        if (n == 8)  return POW10_8;
        if (n == 9)  return POW10_9;
        if (n == 10) return POW10_10;
        if (n == 11) return POW10_11;
        if (n == 12) return POW10_12;
        if (n == 13) return POW10_13;
        if (n == 14) return POW10_14;
        if (n == 15) return POW10_15;
        if (n == 16) return POW10_16;
        if (n == 17) return POW10_17;
        // n == 18
        return POW10_18;
    }

    error EmptyReserves();
    /// price18 = (reserveA * 1e18 * 10^(decB - decA)) / reserveB, computed with overflow-safe mulDiv.
    function _price18(
        uint256 reserveA,
        uint8 decA,
        uint256 reserveB,
        uint8 decB
    ) internal pure returns (uint256) {
        if (reserveA == 0 || reserveB == 0) revert EmptyReserves();
        // Scale factor = 1e18 * 10^(decB - decA)
        uint256 scale;
        unchecked {
            if (decB >= decA) {
                scale = WAD * _pow10(decB - decA);
            } else {
                // Implement as mulDiv(reserveA, WAD, reserveB * 10^(decA - decB))
                uint256 denom = reserveB * _pow10(decA - decB);
                return FullMath.mulDiv(reserveA, WAD, denom);
            }
        }
        return FullMath.mulDiv(reserveA, scale, reserveB);
    }

    /// Scale arbitrary decimals to 1e18.
    function _scaleTo1e18(uint256 amount, uint8 decimals) internal pure returns (uint256 scaled) {
        if (decimals == 18) return amount;
        unchecked {
            if (decimals < 18) {
                return amount * _pow10(18 - decimals);
            } else {
                return amount / _pow10(decimals - 18);
            }
        }
    }
}

abstract contract PoolFinder is ImPoolFinder {
    error PoolDoesNotExist();
    function _findTokenWethPoolAddress(address tokenAddress)
        internal
        view
        returns (bool isV3Pool, address poolAddress)
    {
        Pool memory pool = getPoolFinder().getBestWethPool(tokenAddress);
        if (pool.poolAddress == address(0)) revert PoolDoesNotExist();
        isV3Pool    = pool.isV3Pool != 0;
        poolAddress = pool.poolAddress;
    }
}

abstract contract PriceHelper is POW, Storage, PoolFinder {
    error NotBasePool();
    error ZeroLiquidity();

    /// @notice Base-per-1-token price (1e18 scaled) from a Uniswap V2-like pair.
    /// @dev `baseAddress` must be either token0 or token1 in the pair.
    ///      Returns base units per 1 unit of the *other* token in the pool.
    function _getTokenPriceV2(address poolAddress, address baseAddress) public view returns (uint256 price18) {
        IUniswapV2Pair pool = IUniswapV2Pair(poolAddress);
        address t0 = pool.token0();
        address t1 = pool.token1();

        (uint112 r0, uint112 r1, ) = pool.getReserves();

        bool baseIs0 = (t0 == baseAddress);
        bool baseIs1 = (t1 == baseAddress);
        if (!(baseIs0 || baseIs1) || (baseIs0 && baseIs1)) revert NotBasePool();

        if (baseIs0) {
            // token = t1
            uint8 baseDec  = IERC20Metadata(t0).decimals();
            uint8 tokenDec = IERC20Metadata(t1).decimals();
            price18 = _price18(uint256(r0), baseDec, uint256(r1), tokenDec);
        } else {
            // base = t1, token = t0
            uint8 baseDec  = IERC20Metadata(t1).decimals();
            uint8 tokenDec = IERC20Metadata(t0).decimals();
            price18 = _price18(uint256(r1), baseDec, uint256(r0), tokenDec);
        }
    }

    /// @notice Base-per-1-token price (1e18 scaled) from a Uniswap V3 pool via slot0.
    /// @dev `baseAddress` must be one side. Uses sqrtPriceX96 and handles decimals exactly.
    function _getTokenPriceV3(address poolAddress, address baseAddress) public view returns (uint256 price18) {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        if (pool.liquidity() == 0) revert ZeroLiquidity();

        address t0 = pool.token0();
        address t1 = pool.token1();

        bool baseIs0 = (t0 == baseAddress);
        bool baseIs1 = (t1 == baseAddress);
        if (!(baseIs0 || baseIs1) || (baseIs0 && baseIs1)) revert NotBasePool();

        // P_raw in Q96: token1/token0 * 2^96
        uint256 priceQ96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);

        if (baseIs1) {
            // base = t1, token = t0: want (token1/token0)
            uint8 baseDec  = IERC20Metadata(t1).decimals();
            uint8 tokenDec = IERC20Metadata(t0).decimals();
            unchecked {
                if (tokenDec >= baseDec) {
                    uint256 scale = WAD * _pow10(tokenDec - baseDec);
                    return FullMath.mulDiv(priceQ96, scale, 1 << 96);
                } else {
                    uint256 denom = (1 << 96) * _pow10(baseDec - tokenDec);
                    return FullMath.mulDiv(priceQ96, WAD, denom);
                }
            }
        } else {
            // base = t0, token = t1: want 1 / (token1/token0)
            uint8 baseDec  = IERC20Metadata(t0).decimals();
            uint8 tokenDec = IERC20Metadata(t1).decimals();
            unchecked {
                // **FIX STARTS HERE** (use tokenDec - baseDec, not baseDec - tokenDec)
                if (tokenDec >= baseDec) {
                    // price18 = (1e18 * 10^(tokenDec - baseDec) * 2^96) / priceQ96
                    uint256 numer = WAD * _pow10(tokenDec - baseDec) * (1 << 96);
                    return FullMath.mulDiv(numer, 1, priceQ96);
                } else {
                    // price18 = (1e18 * 2^96) / (priceQ96 * 10^(baseDec - tokenDec))
                    uint256 denom = priceQ96 * _pow10(baseDec - tokenDec);
                    return FullMath.mulDiv(WAD * (1 << 96), 1, denom);
                }
                // **FIX ENDS HERE**
            }
        }
    }



    function _getTokenPrice(address poolAddress, bool isV3Pool, address baseAddress) internal view returns (uint256 price18) {
        if (isV3Pool) {
            price18 = _getTokenPriceV3(poolAddress, baseAddress);
        } else {
            price18 = _getTokenPriceV2(poolAddress, baseAddress);
        }
    }
}

abstract contract WethUsdHelper is PriceHelper {

    function _getWethUsdPrice() internal view returns (uint256 price18) {
        price18 = _getTokenPrice(WETH_USD_PAIR_ADDRESS, IS_WETH_USD_PAIR_ADDRESS_V3, USD_ADDRESS);
    }

    /// @dev Convert a WETH-denominated 1e18 amount to USD 1e18 using the oracle.
    ///      Returns 0 if either the amount or the oracle price is 0.
    function _convertWethToUsd(uint256 wethAmount18) internal view returns (uint256 usdAmount18) {
        if (wethAmount18 == 0) return 0;
        uint256 wethUsdPrice18 = _getWethUsdPrice(); // USD per 1 WETH, 1e18
        if (wethUsdPrice18 == 0) return 0;
        // USD = WETH * (USD/WETH)
        return FullMath.mulDiv(wethAmount18, wethUsdPrice18, WAD);
    }
}

abstract contract LiquidityHelper is WethUsdHelper {
    /// @dev Combines base and token reserves into total WETH value.
    function _calcLiquidityWeth(
        uint256 wethReserve,
        uint8 wethDec,
        uint256 tokenReserve,
        uint8 tokenDec,
        uint256 tokenWethPrice18
    ) internal pure returns (uint256 wethLiquidity18) {
        uint256 wethRes18 = _scaleTo1e18(wethReserve, wethDec);
        uint256 tokenRes18 = _scaleTo1e18(tokenReserve, tokenDec);
        uint256 tokenValueWeth = FullMath.mulDiv(tokenRes18, tokenWethPrice18, WAD);
        wethLiquidity18 = wethRes18 + tokenValueWeth;
    }

    /// @dev Internal helper: Uniswap V2 pool liquidity in WETH terms.
    function _getLiquidityWethV2(address poolAddress) internal view returns (uint256 wethLiquidity18) {
        IUniswapV2Pair pool = IUniswapV2Pair(poolAddress);
        (uint112 r0, uint112 r1, ) = pool.getReserves();
        if (r0 == 0 || r1 == 0) revert EmptyReserves();

        address t0 = pool.token0();
        address t1 = pool.token1();
        bool wethIs0 = (t0 == WETH_ADDRESS);
        bool wethIs1 = (t1 == WETH_ADDRESS);
        if (!(wethIs0 || wethIs1)) revert NotBasePool();

        uint256 tokenWethPrice18 = _getTokenPrice(poolAddress, false, WETH_ADDRESS);

        if (wethIs0) {
            wethLiquidity18 = _calcLiquidityWeth(
                r0,
                IERC20Metadata(t0).decimals(),
                r1,
                IERC20Metadata(t1).decimals(),
                tokenWethPrice18
            );
        } else {
            wethLiquidity18 = _calcLiquidityWeth(
                r1,
                IERC20Metadata(t1).decimals(),
                r0,
                IERC20Metadata(t0).decimals(),
                tokenWethPrice18
            );
        }
    }

    /// @dev Internal helper: Uniswap V3 pool liquidity in WETH terms.
    function _getLiquidityWethV3(address poolAddress) internal view returns (uint256 wethLiquidity18) {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint128 liq = pool.liquidity();
        if (liq == 0) revert ZeroLiquidity();

        address t0 = pool.token0();
        address t1 = pool.token1();
        bool wethIs0 = (t0 == WETH_ADDRESS);
        bool wethIs1 = (t1 == WETH_ADDRESS);
        if (!(wethIs0 || wethIs1)) revert NotBasePool();

        // approximate virtual reserves
        uint256 sqrtP = uint256(sqrtPriceX96);
        uint256 reserve0 = FullMath.mulDiv(uint256(liq) << 96, 1, sqrtP);
        uint256 reserve1 = FullMath.mulDiv(uint256(liq) * sqrtP, 1, 1 << 96);
        uint256 tokenWethPrice18 = _getTokenPrice(poolAddress, true, WETH_ADDRESS);

        if (wethIs0) {
            wethLiquidity18 = _calcLiquidityWeth(
                reserve0,
                IERC20Metadata(t0).decimals(),
                reserve1,
                IERC20Metadata(t1).decimals(),
                tokenWethPrice18
            );
        } else {
            wethLiquidity18 = _calcLiquidityWeth(
                reserve1,
                IERC20Metadata(t1).decimals(),
                reserve0,
                IERC20Metadata(t0).decimals(),
                tokenWethPrice18
            );
        }
    }

    /// @notice Total pool liquidity in WETH for the TOKEN–WETH pair (scaled 1e18).
    /// If TOKEN is WETH, returns WETH totalSupply (scaled to 1e18).
    function _getTokenLiquidityWeth(address tokenAddress) internal view returns (uint256 wethLiquidity18) {
        if (tokenAddress == WETH_ADDRESS) {
            uint256 supply = IERC20(WETH_ADDRESS).totalSupply();
            return _scaleTo1e18(supply, WETH_DECIMALS);
        }

        (bool isV3Pool, address poolAddress) = _findTokenWethPoolAddress(tokenAddress);
        if (isV3Pool) {
            wethLiquidity18 = _getLiquidityWethV3(poolAddress);
        } else {
            wethLiquidity18 = _getLiquidityWethV2(poolAddress);
        }
    }
    
}

contract UniswapOracle is LiquidityHelper {

    constructor(
        address _directory,
        address _wethAddress,
        address _wethUsdPoolAddress,
        bool _isWethUsdPoolV3
    ) ImDirectory(_directory) {
        WETH_ADDRESS = _wethAddress;
        WETH_USD_PAIR_ADDRESS = _wethUsdPoolAddress;
        IS_WETH_USD_PAIR_ADDRESS_V3 = _isWethUsdPoolV3;

        WETH_DECIMALS = IERC20Metadata(_wethAddress).decimals();

        if (_isWethUsdPoolV3) {
            IUniswapV3Pool pool = IUniswapV3Pool(_wethUsdPoolAddress);
            address t0 = pool.token0();
            address t1 = pool.token1();
            USD_ADDRESS = t0 == _wethAddress ? t1 : t0;
        } else {
            IUniswapV2Pair pool = IUniswapV2Pair(_wethUsdPoolAddress);
            address t0 = pool.token0();
            address t1 = pool.token1();
            USD_ADDRESS = t0 == _wethAddress ? t1 : t0;
        }
    }

    // -- Read fns --
    function getWethUsdPrice() public view returns (uint256 price18) {
        return _getWethUsdPrice();
    }

    function getTokenWethPrice(address tokenAddress) public view returns (uint256) {
        if (tokenAddress == WETH_ADDRESS) {
            return WAD;
        }
        (bool isV3Pool, address poolAddress) = _findTokenWethPoolAddress(tokenAddress);

        return _getTokenPrice(poolAddress, isV3Pool, WETH_ADDRESS);
    }

    /// @notice USD price of 1 TOKEN (scaled 1e18).
    function getTokenUsdPrice(address tokenAddress) external view returns (uint256 price18) {
        uint256 tokenWeth = getTokenWethPrice(tokenAddress); // WETH per 1 TOKEN (1e18)
        price18 = _convertWethToUsd(tokenWeth);
    }

    /// @notice Total pool liquidity in WETH for the TOKEN–WETH pair (scaled 1e18).
    /// If TOKEN is WETH, returns WETH totalSupply (scaled to 1e18).
    function getTokenLiquidityWeth(address tokenAddress) public view returns (uint256) {
        return _getTokenLiquidityWeth(tokenAddress);
    }

    /// @notice Total pool liquidity in USD for the TOKEN–WETH pair (scaled 1e18).
    function getTokenLiquidityUsd(address tokenAddress) external view returns (uint256 totalLiquidityUsd18) {
        uint256 totalLiquidityWeth18 = getTokenLiquidityWeth(tokenAddress);
        totalLiquidityUsd18 = _convertWethToUsd(totalLiquidityWeth18);
    }

    /// @notice Market cap in WETH for TOKEN (scaled 1e18): totalSupply * (WETH per 1 TOKEN).
    /// If TOKEN is WETH, this is simply WETH totalSupply (scaled 1e18).
    function getTokenMarketCapWeth(address tokenAddress) public view returns (uint256) {
        uint256 supply  = IERC20(tokenAddress).totalSupply();
        uint8   decT    = IERC20Metadata(tokenAddress).decimals();
        uint256 supply18 = _scaleTo1e18(supply, decT);

        if (tokenAddress == WETH_ADDRESS) {
            return supply18; // price == 1 WETH
        }
        uint256 wethPerToken18 = getTokenWethPrice(tokenAddress);
        return FullMath.mulDiv(supply18, wethPerToken18, WAD);
    }

    /// @notice Market cap in USD for TOKEN (scaled 1e18).
    function getTokenMarketCapUsd(address tokenAddress) external view returns (uint256 marketCapUsd18) {
        uint256 mcWeth18     = getTokenMarketCapWeth(tokenAddress);
        uint256 usdPerWeth18 = getWethUsdPrice();
        marketCapUsd18 = FullMath.mulDiv(mcWeth18, usdPerWeth18, WAD);
    }

    function getTokenWethPoolAddress(address tokenAddress) external view returns (bool isV3Pool, address poolAddress) {
        return _findTokenWethPoolAddress(tokenAddress);
    }

    function emitPoolChangedEventOnWethUsdPool() external onlyOwner {
        getPoolFinder().emitPoolChangedEventOnWethUsdPool(WETH_USD_PAIR_ADDRESS, IS_WETH_USD_PAIR_ADDRESS_V3);
    }
}