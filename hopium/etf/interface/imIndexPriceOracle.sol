// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/storage/index.sol";

interface IIndexPriceOracle {
   function getIndexWethPrice(uint256 indexId) external view returns (uint256);
   function getIndexUsdPrice(uint256 indexId) external view returns (uint256);
}

abstract contract ImIndexPriceOracle is ImDirectory {

    function getIndexPriceOracle() internal view virtual returns (IIndexPriceOracle) {
        return IIndexPriceOracle(fetchFromDirectory("index-price-oracle"));
    }
}