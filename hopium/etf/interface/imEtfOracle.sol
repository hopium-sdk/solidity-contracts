// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/types/etf.sol";
import "hopium/etf/interface/iEtfOracle.sol";

abstract contract ImEtfOracle is ImDirectory {

    function getEtfOracle() internal view virtual returns (IEtfOracle) {
        return IEtfOracle(fetchFromDirectory("etf-oracle"));
    }
}