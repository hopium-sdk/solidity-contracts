// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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