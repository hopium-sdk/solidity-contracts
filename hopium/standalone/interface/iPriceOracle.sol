// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IPriceOracle {
    function getTokenWethPrice(address tokenAddress) external view returns (uint256 price18);
    function getTokenUsdPrice(address tokenAddress) external view returns (uint256 price18);
    function getWethUsdPrice() external view returns (uint256 price18);
}
