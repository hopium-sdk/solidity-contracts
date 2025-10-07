// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/storage/index.sol";
import "hopium/etf/interface/imIndexFactory.sol";
import "hopium/standalone/interface/imPriceOracle.sol";
import "hopium/common/storage/bips.sol"; // for HUNDRED_PERCENT_BIPS

abstract contract Helpers {
    /// @dev Shared helper: computes the weighted index price using a provided pricing fn.
    /// @param index The index definition (holdings + weights).
    /// @param priceFn A function that returns the 1e18-scaled price for a given WETH pair address.
    function _weightedIndexPrice(
        Index memory index,
        function(address) external view returns (uint256) priceFn
    ) internal view returns (uint256) {
        uint256 n = index.holdings.length;
        uint256 weightedSum; // accumulates 1e18 * bips

        for (uint256 i = 0; i < n; i++) {
            Holding memory h = index.holdings[i];
            uint256 p = priceFn(h.tokenAddress); // 1e18-scaled
            weightedSum += p * uint256(h.weightBips);
        }

        return weightedSum / HUNDRED_PERCENT_BIPS; // keep 1e18 scale
    }
}

contract IndexPriceOracle is ImDirectory, ImIndexFactory, ImPriceOracle, Helpers {
    constructor(address _directory) ImDirectory(_directory) {}

    // -- read fns --

    function getIndexWethPrice(uint256 indexId) external view returns (uint256) {
        Index memory index = getIndexFactory().getIndexById(indexId);
        IPriceOracle o = getPriceOracle();
        return _weightedIndexPrice(index, o.getTokenWethPrice);
    }

    function getIndexUsdPrice(uint256 indexId) external view returns (uint256) {
        Index memory index = getIndexFactory().getIndexById(indexId);
        IPriceOracle o = getPriceOracle();
        return _weightedIndexPrice(index, o.getTokenUsdPrice);
    }
}
