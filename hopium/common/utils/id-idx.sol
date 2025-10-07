// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

abstract contract IdIdxUtils {

    function _idxToId(uint256 idx) internal pure returns (uint256) {
        return idx + 1;
    }

    function _idToIdx(uint256 id) internal pure returns (uint256) {
        return id - 1;
    }
}