// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

abstract contract Storage {
    address public WETH_ADDRESS;
    address public WETH_USD_PAIR_ADDRESS;
    address public UNISWAP_V2_FACTORY_ADDRESS;
}

abstract contract Helpers is Storage {
    /// @dev Returns reserves and decimals ordered so that the first tuple corresponds to `baseToken`.
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
            revert("Pair does not contain base token");
        }

        reserveBase  = baseIsToken0 ? uint256(r0) : uint256(r1);
        reserveQuote = baseIsToken0 ? uint256(r1) : uint256(r0);
        quoteToken   = baseIsToken0 ? t1 : t0;

        // Use metadata for decimals so helpers are reusable (WETH is typically 18, but don't assume).
        decBase  = IERC20Metadata(baseToken).decimals();
        decQuote = IERC20Metadata(quoteToken).decimals();
    }

    /// @dev Compute price as "amountA per 1 unit of B", scaled to 1e18.
    /// price18 = (reserveA * 10^(18 + decB - decA)) / reserveB
    function _computePrice18(
        uint256 reserveA,
        uint8 decA,
        uint256 reserveB,
        uint8 decB
    ) internal pure returns (uint256 price18) {
        uint256 num = reserveA * 1e18;
        if (decB > decA) {
            num *= 10 ** uint256(decB - decA);
        } else if (decA > decB) {
            num /= 10 ** uint256(decA - decB);
        }
        price18 = num / reserveB;
    }

    function _getTokenToWethPairAddress(address tokenAddress) internal view returns (address) {
        address pairAddress = IUniswapV2Factory(UNISWAP_V2_FACTORY_ADDRESS).getPair(tokenAddress, WETH_ADDRESS);
        require (pairAddress != address(0), "UniswapV2Pair: pair does not exist" );

        return pairAddress;
    }

    function _scaleTo1e18(uint256 amount, uint8 decimals) internal pure returns (uint256 scaled) {
        if (decimals == 18) return amount;
        if (decimals < 18) {
            scaled = amount * (10 ** uint256(18 - decimals));
        } else {
            scaled = amount / (10 ** uint256(decimals - 18));
        }
    }
}

contract PriceOracle is Helpers {
    constructor(address _wethAddress, address _wethUsdPairAddress, address _uniswapV2FactoryAddress) {
        WETH_ADDRESS = _wethAddress;
        WETH_USD_PAIR_ADDRESS = _wethUsdPairAddress;
        UNISWAP_V2_FACTORY_ADDRESS = _uniswapV2FactoryAddress;
    }

    /// @notice Returns USD per 1 WETH (scaled 1e18) using the stored WETH/USD pair.
    function getWethUsdPrice() public view returns (uint256 price18) {
        (uint256 reserveWeth, uint8 decW, uint256 reserveUsd, uint8 decU,) = _getOrderedReserves(WETH_USD_PAIR_ADDRESS, WETH_ADDRESS);

        // USD per 1 WETH
        price18 = _computePrice18(reserveUsd, decU, reserveWeth, decW);
    }

    /// @notice Returns WETH per 1 QUOTE (scaled 1e18) for an arbitrary WETH-QUOTE pair.
    function getTokenWethPrice(address tokenAddress) public view returns (uint256 price18) {
        address pairAddress = _getTokenToWethPairAddress(tokenAddress);
        (uint256 reserveWeth, uint8 decW, uint256 reserveQuote, uint8 decQ,) = _getOrderedReserves(pairAddress, WETH_ADDRESS);

        // WETH per 1 QUOTE
        price18 = _computePrice18(reserveWeth, decW, reserveQuote, decQ);
    }

    /// @notice Returns USD price of 1 TOKEN (scaled to 1e18)
    function getTokenUsdPrice(address tokenAddress) public view returns (uint256 price18) {
        uint256 tokenWeth = getTokenWethPrice(tokenAddress); // WETH per 1 TOKEN
        uint256 wethUsd   = getWethUsdPrice();              // USD per 1 WETH

        // tokenUsd = (WETH per TOKEN) * (USD per WETH)
        price18 = (tokenWeth * wethUsd) / 1e18;
    }

    // @notice Returns total pool liquidity in WETH for the TOKEN–WETH pair.
    function getTokenLiquidityWeth(address tokenAddress) public view returns (uint256 totalLiquidityWeth18) {
        address pairAddress = _getTokenToWethPairAddress(tokenAddress);

        (uint256 reserveToken, uint8 decT, uint256 reserveWeth, uint8 decW,) = _getOrderedReserves(pairAddress, tokenAddress);

        uint256 tokenAmount18 = _scaleTo1e18(reserveToken, decT);
        uint256 wethAmount18  = _scaleTo1e18(reserveWeth, decW);

        // WETH per 1 TOKEN (scaled 1e18)
        uint256 tokenPriceInWeth18 = getTokenWethPrice(tokenAddress);

        // Value of TOKEN side in WETH
        uint256 tokenValueInWeth18 = (tokenAmount18 * tokenPriceInWeth18) / 1e18;

        // Total liquidity in WETH = TOKEN value (in WETH) + WETH reserve
        totalLiquidityWeth18 = tokenValueInWeth18 + wethAmount18;
    }

    // @notice Returns total pool liquidity in USD for the TOKEN–WETH pair.
    function getTokenLiquidityUsd(address tokenAddress) external view returns (uint256 totalLiquidityUsd18) {
        uint256 totalLiquidityWeth18 = getTokenLiquidityWeth(tokenAddress);
        uint256 usdPerWeth18 = getWethUsdPrice();

        totalLiquidityUsd18 = (totalLiquidityWeth18 * usdPerWeth18) / 1e18;
    }

    /// @notice Returns market cap in WETH for TOKEN (scaled 1e18): totalSupply * (WETH per 1 TOKEN).
    function getTokenMarketCapWeth(address tokenAddress) public view returns (uint256 marketCapWeth18) {
        uint256 supply = IERC20(tokenAddress).totalSupply();
        uint8 decT = IERC20Metadata(tokenAddress).decimals();
        uint256 supply18 = _scaleTo1e18(supply, decT);          // normalize totalSupply to 1e18
        uint256 wethPerToken18 = getTokenWethPrice(tokenAddress);
        marketCapWeth18 = (supply18 * wethPerToken18) / 1e18;
    }

    /// @notice Returns market cap in USD for TOKEN (scaled 1e18).
    function getTokenMarketCapUsd(address tokenAddress) external view returns (uint256 marketCapUsd18) {
        uint256 mcWeth18 = getTokenMarketCapWeth(tokenAddress);
        uint256 usdPerWeth18 = getWethUsdPrice();
        marketCapUsd18 = (mcWeth18 * usdPerWeth18) / 1e18;
    }

}
