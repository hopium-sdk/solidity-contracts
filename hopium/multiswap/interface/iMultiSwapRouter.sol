// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

struct SwapOrderInput {
    address tokenAddress;
    uint256 amount;
}

struct SwapOrderOutput {
    address tokenAddress;
    uint16 weightBips;
}

struct SwapFee {
    address feeAddress;
    uint16 feeBips;
}


interface IMultiSwapRouter {
    function swap(SwapOrderInput[] calldata inputs, SwapOrderOutput[] calldata outputs, address receiver, uint256 slippageBips, uint256 deadlineInSec, SwapFee[] calldata fees) external payable;
}