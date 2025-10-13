// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/multiswap-eth/types/types.sol";

interface IMultiSwapEthRouter {
   function swapEthToMultipleTokens(
        MultiTokenOutput[] calldata outputs,
        address recipientAddress,
        uint32 slippageBps
    ) external payable;

    function swapMultipleTokensToEth(
        MultiTokenInput[] calldata inputsIn,
        address payable recipientAddress,
        uint32 slippageBps,
        bool preTransferred
    ) external;

    function getBestWethPool(address tokenAddress) external view returns (Pool memory pool);
    function getBestWethPoolUpdatable(address tokenAddress) external returns (Pool memory pool);
}