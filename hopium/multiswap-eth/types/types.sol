// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

struct MultiTokenInput {
    address tokenAddress;
    uint256 amount; // For tokens->ETH: amount of the ERC20 to sell
}

struct MultiTokenOutput {
    address tokenAddress;
    uint16  weightBips; // Weight in basis points (must sum to <= 10_000)
}

struct Pool {
    address poolAddress; // 20
    uint24  poolFee;     // 3
    uint8   isV3Pool;    // 1 (0/1)
    uint64  lastCached;  // 8
}