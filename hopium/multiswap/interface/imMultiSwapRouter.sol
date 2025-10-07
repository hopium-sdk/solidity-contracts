// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/multiswap/interface/iMultiSwapRouter.sol";

abstract contract ImMultiSwapRouter is ImDirectory {

    function getMultiSwapRouter() internal view virtual returns (IMultiSwapRouter) {
        return IMultiSwapRouter(fetchFromDirectory("multiswap-router"));
    }
}