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