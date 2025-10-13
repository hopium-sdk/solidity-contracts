// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/types/index.sol";

interface IIndexFactory {
    function createIndex(Index calldata index) external returns (uint256);
    function getIndexById(uint256 indexId) external view returns (Index memory);
}

abstract contract ImIndexFactory is ImDirectory {

    function getIndexFactory() internal view virtual returns (IIndexFactory) {
        return IIndexFactory(fetchFromDirectory("index-factory"));
    }
}