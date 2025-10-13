// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/uniswap/types/multiswap.sol";
import "hopium/common/interface/imDirectory.sol";

interface IMultiSwapRouter {
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
}

abstract contract ImMultiSwapRouter is ImDirectory {

    function getMultiSwapRouter() internal view virtual returns (IMultiSwapRouter) {
        return IMultiSwapRouter(fetchFromDirectory("multi-swap-router"));
    }
}