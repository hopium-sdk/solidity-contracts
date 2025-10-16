// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IUniswapOracle {
    function getTokenWethPrice(address tokenAddress) external view returns (uint256 price18);
    function getTokenUsdPrice(address tokenAddress) external view returns (uint256 price18);
    function getWethUsdPrice() external view returns (uint256 price18);
    function getTokenLiquidityWeth(address) external view returns (uint256);
    function getTokenLiquidityUsd(address) external view returns (uint256);
    function getTokenMarketCapWeth(address) external view returns (uint256);
    function getTokenMarketCapUsd(address) external view returns (uint256);
}
