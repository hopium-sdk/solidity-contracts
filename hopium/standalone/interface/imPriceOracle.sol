// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/standalone/interface/iPriceOracle.sol";

abstract contract ImPriceOracle is ImDirectory {

    function getPriceOracle() internal view virtual returns (IPriceOracle) {
        return IPriceOracle(fetchFromDirectory("price-oracle"));
    }
}