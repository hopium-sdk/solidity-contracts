// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC20 {
    function totalSupply() external view returns (uint256);
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

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

abstract contract Storage {
    address public immutable WETH_ADDRESS;
    address public immutable WETH_USD_PAIR_ADDRESS;
    address public immutable UNISWAP_V2_FACTORY_ADDRESS;

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
}

abstract contract Helpers is POW, Storage {

    error PairDoesNotExist();
    function _getTokenToWethPairAddress(address tokenAddress) internal view returns (address pairAddress) {
        pairAddress = IUniswapV2Factory(UNISWAP_V2_FACTORY_ADDRESS).getPair(tokenAddress, WETH_ADDRESS);
        if (pairAddress == address(0)) revert PairDoesNotExist();
    }

    error PairDoesNotContainBase();
    /// Returns reserves ordered so that `reserveBase` corresponds to `baseToken`,
    /// plus decimals and the other token address as `quoteToken`.
    function _getOrderedReserves(address pairAddress, address baseToken)
        internal
        view
        returns (
            uint256 reserveBase,
            uint8 decBase,
            uint256 reserveQuote,
            uint8 decQuote,
            address quoteToken
        )
    {
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);

        (uint112 r0, uint112 r1, ) = pair.getReserves();
        address t0 = pair.token0();
        address t1 = pair.token1();

        bool baseIsToken0;
        if (t0 == baseToken) {
            baseIsToken0 = true;
        } else if (t1 == baseToken) {
            baseIsToken0 = false;
        } else {
            revert PairDoesNotContainBase();
        }

        reserveBase  = uint256(baseIsToken0 ? r0 : r1);
        reserveQuote = uint256(baseIsToken0 ? r1 : r0);
        quoteToken   = baseIsToken0 ? t1 : t0;

        decBase  = IERC20Metadata(baseToken).decimals();
        decQuote = IERC20Metadata(quoteToken).decimals();
    }

    /// price18 = (reserveA * 1e18 * 10^(decB - decA)) / reserveB, computed with overflow-safe mulDiv.
    function _price18(
        uint256 reserveA,
        uint8 decA,
        uint256 reserveB,
        uint8 decB
    ) internal pure returns (uint256) {
        // Scale factor = 1e18 * 10^(decB - decA)
        uint256 scale;
        unchecked {
            if (decB >= decA) {
                scale = WAD * _pow10(decB - decA);
            } else {
                // When decA > decB we divide by 10^(decA - decB) after mulDiv
                // i.e., equivalent to scaling denominator.
                // Implement as mulDiv(reserveA, WAD, reserveB * 10^(decA - decB))
                uint256 denom = reserveB * _pow10(decA - decB);
                return _mulDiv(reserveA, WAD, denom);
            }
        }
        return _mulDiv(reserveA, scale, reserveB);
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

    /// Full-precision mulDiv from Uniswap v3 (slightly adapted) — computes floor(a*b/denominator)
    /// without overflow, with 512-bit intermediate.
    function _mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            uint256 prod0; // least significant 256 bits
            uint256 prod1; // most significant 256 bits
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                // fits in 256 bits
                return prod0 / denominator;
            }
            // Make sure the result is less than 2^256. Also prevents denominator == 0
            require(denominator > prod1, "mulDiv overflow");

            // Compute remainder, subtract from [prod1 prod0]
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1) // twos = 2^n
            }
            // Shift bits from prod1 into prod0
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // inverse mod 2^8
            inv *= 2 - denominator * inv; // mod 2^16
            inv *= 2 - denominator * inv; // mod 2^32
            inv *= 2 - denominator * inv; // mod 2^64
            inv *= 2 - denominator * inv; // mod 2^128
            inv *= 2 - denominator * inv; // mod 2^256

            // result = prod0 * inv mod 2^256
            result = prod0 * inv;
            return result;
        }
    }
}

contract PriceOracle is Helpers {
    
    constructor(
        address _wethAddress,
        address _wethUsdPairAddress,
        address _uniswapV2FactoryAddress
    ) {
        WETH_ADDRESS = _wethAddress;
        WETH_USD_PAIR_ADDRESS = _wethUsdPairAddress;
        UNISWAP_V2_FACTORY_ADDRESS = _uniswapV2FactoryAddress;

        WETH_DECIMALS = IERC20Metadata(_wethAddress).decimals();
    }

    // -- Read fns --

    /// @notice USD per 1 WETH (scaled 1e18) using the stored WETH/USD pair.
    function getWethUsdPrice() public view returns (uint256 price18) {
        (
            uint256 reserveWeth,
            uint8 decW,
            uint256 reserveUsd,
            uint8 decU,

        ) = _getOrderedReserves(WETH_USD_PAIR_ADDRESS, WETH_ADDRESS);

        // price = (reserveUsd * 1e18 * 10^(decW - decU? no → see formula below)) / reserveWeth
        // We compute: (reserveUsd * 1e18 * 10^(decW? no)) / (reserveWeth * 10^(decU? no))
        price18 = _price18(reserveUsd, decU, reserveWeth, decW);
    }

    /// @notice WETH per 1 TOKEN (scaled 1e18) for an arbitrary TOKEN–WETH pair.
    /// If TOKEN is WETH, returns 1e18.
    function getTokenWethPrice(address tokenAddress) public view returns (uint256) {
        if (tokenAddress == WETH_ADDRESS) {
            return WAD;
        }
        address pairAddress = _getTokenToWethPairAddress(tokenAddress);
        (uint256 reserveWeth, uint8 decW, uint256 reserveToken, uint8 decT,) =
            _getOrderedReserves(pairAddress, WETH_ADDRESS);

        // WETH per 1 TOKEN = (reserveWeth / reserveToken) * 10^(decT - decW), scaled to 1e18
        return _price18(reserveWeth, decW, reserveToken, decT);
    }

    /// @notice USD price of 1 TOKEN (scaled 1e18).
    function getTokenUsdPrice(address tokenAddress) external view returns (uint256 price18) {
        uint256 tokenWeth = getTokenWethPrice(tokenAddress); // WETH per 1 TOKEN (1e18)
        uint256 wethUsd   = getWethUsdPrice();               // USD per 1 WETH (1e18)
        // tokenUsd = tokenWeth * wethUsd / 1e18
        price18 = _mulDiv(tokenWeth, wethUsd, WAD);
    }

    /// @notice Total pool liquidity in WETH for the TOKEN–WETH pair (scaled 1e18).
    /// If TOKEN is WETH, returns WETH totalSupply (scaled to 1e18).
    function getTokenLiquidityWeth(address tokenAddress) public view returns (uint256) {
        if (tokenAddress == WETH_ADDRESS) {
            uint256 supply = IERC20(WETH_ADDRESS).totalSupply();
            return _scaleTo1e18(supply, WETH_DECIMALS);
        }

        address pairAddress = _getTokenToWethPairAddress(tokenAddress);
        (uint256 reserveToken, uint8 decT, uint256 reserveWeth, uint8 decW,) =
            _getOrderedReserves(pairAddress, tokenAddress);

        uint256 tokenAmount18 = _scaleTo1e18(reserveToken, decT);
        uint256 wethAmount18  = _scaleTo1e18(reserveWeth,  decW);

        // WETH per 1 TOKEN (1e18)
        uint256 tokenPriceInWeth18 = getTokenWethPrice(tokenAddress);

        // Value of TOKEN side in WETH (1e18)
        uint256 tokenValueInWeth18 = _mulDiv(tokenAmount18, tokenPriceInWeth18, WAD);

        // Total liquidity = TOKEN value (in WETH) + WETH reserve
        unchecked { // addition of two 1e18-scaled reserves is safe in practice
            return tokenValueInWeth18 + wethAmount18;
        }
    }

    /// @notice Total pool liquidity in USD for the TOKEN–WETH pair (scaled 1e18).
    function getTokenLiquidityUsd(address tokenAddress) external view returns (uint256 totalLiquidityUsd18) {
        uint256 totalLiquidityWeth18 = getTokenLiquidityWeth(tokenAddress);
        uint256 usdPerWeth18         = getWethUsdPrice();
        totalLiquidityUsd18 = _mulDiv(totalLiquidityWeth18, usdPerWeth18, WAD);
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
        return _mulDiv(supply18, wethPerToken18, WAD);
    }

    /// @notice Market cap in USD for TOKEN (scaled 1e18).
    function getTokenMarketCapUsd(address tokenAddress) external view returns (uint256 marketCapUsd18) {
        uint256 mcWeth18     = getTokenMarketCapWeth(tokenAddress);
        uint256 usdPerWeth18 = getWethUsdPrice();
        marketCapUsd18 = _mulDiv(mcWeth18, usdPerWeth18, WAD);
    }

    function getTokenWethPairAddress(address tokenAddress) external view returns (address) {
        return _getTokenToWethPairAddress(tokenAddress);
    }

}
