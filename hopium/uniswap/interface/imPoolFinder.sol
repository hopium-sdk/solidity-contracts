// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/uniswap/types/pool.sol";
import "hopium/common/interface/imDirectory.sol";

interface IPoolFinder {
    function getBestWethPool(address tokenAddress) external view returns (Pool memory pool);
    function getBestWethPoolAndUpdateIfStale(address tokenAddress) external returns (Pool memory pool);
    function getBestWethPoolAndForceUpdate(address tokenAddress) external returns (Pool memory out);
    function emitPoolChangedEventOnWethUsdPool(address poolAddress, bool isV3Pool) external;
}

abstract contract ImPoolFinder is ImDirectory {

    function getPoolFinder() internal view virtual returns (IPoolFinder) {
        return IPoolFinder(fetchFromDirectory("pool-finder"));
    }
}