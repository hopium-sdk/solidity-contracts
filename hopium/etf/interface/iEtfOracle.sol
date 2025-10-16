// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/etf/types/etf.sol";

struct Snapshot {
    address tokenAddress;
    uint8   tokenDecimals;
    uint16  currentWeight;
    uint256 tokenRawBalance;          // vault raw balance
    uint256 tokenPriceWeth18;  // WETH per 1 token (1e18)
    uint256 tokenValueWeth18;  // raw * price / 10^dec
}

struct SnapshotWithUsd {
    address tokenAddress;
    uint8   tokenDecimals;
    uint16  currentWeight;
    uint256 tokenRawBalance;          // vault raw balance
    uint256 tokenPriceWeth18;  // WETH per 1 token (1e18)
    uint256 tokenPriceUsd18;
    uint256 tokenValueWeth18;  // raw * price / 10^dec
    uint256 tokenValueUsd18;
}

interface IEtfOracle {
   function getEtfWethPrice(uint256 etfId) external view returns (uint256);
   function getEtfUsdPrice(uint256 etfId) external view returns (uint256);
   function snapshotVaultUnchecked(Etf memory etf, address vaultAddress) external view returns (Snapshot[] memory s, uint256 etfTvlWeth);
}