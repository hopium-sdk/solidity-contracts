// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/storage/index.sol";
import "hopium/etf/interface/imIndexFactory.sol";
import "hopium/standalone/interface/imPriceOracle.sol";
import "hopium/common/storage/bips.sol"; // for HUNDRED_PERCENT_BIPS

abstract contract Helpers {
    /// @dev Shared helper: computes a weighted metric over index holdings using the supplied metric function.
    /// @param index The index definition (holdings + weights).
    /// @param metricFn A function that returns a 1e18-scaled metric for a given token address.
    function _weightedIndexMetric(
        Index memory index,
        function(address) external view returns (uint256) metricFn
    ) internal view returns (uint256) {
        uint256 n = index.holdings.length;
        uint256 weightedSum; // accumulates metric * bips (still 1e18-scaled after division)

        for (uint256 i = 0; i < n; i++) {
            Holding memory h = index.holdings[i];
            uint256 m = metricFn(h.tokenAddress); // 1e18-scaled metric
            weightedSum += m * uint256(h.weightBips);
        }

        return weightedSum / HUNDRED_PERCENT_BIPS; // keep 1e18 scaling
    }

    /// @dev Back-compat alias retained for price (calls the generic metric helper).
    function _weightedIndexPrice(
        Index memory index,
        function(address) external view returns (uint256) priceFn
    ) internal view returns (uint256) {
        return _weightedIndexMetric(index, priceFn);
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

    /// @notice Weighted liquidity in WETH (1e18) across index components.
    function getIndexLiquidityWeth(uint256 indexId) external view returns (uint256) {
        Index memory index = getIndexFactory().getIndexById(indexId);
        IPriceOracle o = getPriceOracle();
        return _weightedIndexMetric(index, o.getTokenLiquidityWeth);
    }

    /// @notice Weighted liquidity in USD (1e18) across index components.
    function getIndexLiquidityUsd(uint256 indexId) external view returns (uint256) {
        Index memory index = getIndexFactory().getIndexById(indexId);
        IPriceOracle o = getPriceOracle();
        return _weightedIndexMetric(index, o.getTokenLiquidityUsd);
    }

    /// @notice Weighted market cap in WETH (1e18) across index components.
    function getIndexMarketCapWeth(uint256 indexId) external view returns (uint256) {
        Index memory index = getIndexFactory().getIndexById(indexId);
        IPriceOracle o = getPriceOracle();
        return _weightedIndexMetric(index, o.getTokenMarketCapWeth);
    }

    /// @notice Weighted market cap in USD (1e18) across index components.
    function getIndexMarketCapUsd(uint256 indexId) external view returns (uint256) {
        Index memory index = getIndexFactory().getIndexById(indexId);
        IPriceOracle o = getPriceOracle();
        return _weightedIndexMetric(index, o.getTokenMarketCapUsd);
    }
}
