// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/uniswap/interface/iUniswapOracle.sol";

abstract contract ImUniswapOracle is ImDirectory {

    function getUniswapOracle() internal view virtual returns (IUniswapOracle) {
        return IUniswapOracle(fetchFromDirectory("uniswap-oracle"));
    }
}