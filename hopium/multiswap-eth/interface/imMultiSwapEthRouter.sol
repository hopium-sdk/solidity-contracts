// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/multiswap-eth/interface/iMultiSwapEthRouter.sol";

abstract contract ImMultiSwapEthRouter is ImDirectory {

    function getMultiSwapEthRouter() internal view virtual returns (IMultiSwapEthRouter) {
        return IMultiSwapEthRouter(fetchFromDirectory("multiswap-eth-router"));
    }
}