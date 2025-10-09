// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/storage/index.sol";
import "hopium/etf/interface/imIndexFactory.sol";
import "hopium/standalone/interface/imPriceOracle.sol";
import "hopium/common/storage/bips.sol"; // HUNDRED_PERCENT_BIPS

abstract contract Helpers {
    /// @dev Weighted sum: Σ (metric(token) * weightBips) / 10_000
    function _weightedMetric(
        Index memory idx,
        function(IPriceOracle,address) view returns (uint256) callMetric,
        IPriceOracle o
    ) internal view returns (uint256 sum) {
        Holding[] memory hs = idx.holdings;
        uint256 n = hs.length;
        for (uint256 i = 0; i < n; ) {
            // load straight to stack; avoid struct temp
            address token = hs[i].tokenAddress;
            uint256 w = hs[i].weightBips;
            uint256 m = callMetric(o, token); // 1e18 scaled
            unchecked {
                sum += m * w;
                ++i;
            }
        }
        // keep 1e18 scaling
        return sum / HUNDRED_PERCENT_BIPS;
    }

    // Small wrappers so we avoid function-pointer to external function (cheaper)
    function _metricWethPrice(IPriceOracle o, address token) internal view returns (uint256) {
        return o.getTokenWethPrice(token);
    }
    function _metricUsdPrice(IPriceOracle o, address token) internal view returns (uint256) {
        return o.getTokenUsdPrice(token);
    }
    function _metricLiqWeth(IPriceOracle o, address token) internal view returns (uint256) {
        return o.getTokenLiquidityWeth(token);
    }
    function _metricLiqUsd(IPriceOracle o, address token) internal view returns (uint256) {
        return o.getTokenLiquidityUsd(token);
    }
    function _metricCapWeth(IPriceOracle o, address token) internal view returns (uint256) {
        return o.getTokenMarketCapWeth(token);
    }
    function _metricCapUsd(IPriceOracle o, address token) internal view returns (uint256) {
        return o.getTokenMarketCapUsd(token);
    }
}

contract IndexPriceOracle is ImDirectory, ImIndexFactory, ImPriceOracle, Helpers {
    constructor(address _directory) ImDirectory(_directory) {}

    // -- read fns --

    function getIndexWethPrice(uint256 indexId) external view returns (uint256) {
        Index memory idx = getIndexFactory().getIndexById(indexId);
        IPriceOracle o = getPriceOracle();
        return _weightedMetric(idx, _metricWethPrice, o);
    }

    function getIndexUsdPrice(uint256 indexId) external view returns (uint256) {
        Index memory idx = getIndexFactory().getIndexById(indexId);
        IPriceOracle o = getPriceOracle();
        return _weightedMetric(idx, _metricUsdPrice, o);
    }

    function getIndexLiquidityWeth(uint256 indexId) external view returns (uint256) {
        Index memory idx = getIndexFactory().getIndexById(indexId);
        IPriceOracle o = getPriceOracle();
        return _weightedMetric(idx, _metricLiqWeth, o);
    }

    function getIndexLiquidityUsd(uint256 indexId) external view returns (uint256) {
        Index memory idx = getIndexFactory().getIndexById(indexId);
        IPriceOracle o = getPriceOracle();
        return _weightedMetric(idx, _metricLiqUsd, o);
    }

    function getIndexMarketCapWeth(uint256 indexId) external view returns (uint256) {
        Index memory idx = getIndexFactory().getIndexById(indexId);
        IPriceOracle o = getPriceOracle();
        return _weightedMetric(idx, _metricCapWeth, o);
    }

    function getIndexMarketCapUsd(uint256 indexId) external view returns (uint256) {
        Index memory idx = getIndexFactory().getIndexById(indexId);
        IPriceOracle o = getPriceOracle();
        return _weightedMetric(idx, _metricCapUsd, o);
    }
}
