// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library IdIdx {

    function idxToId(uint256 idx) internal pure returns (uint256) {
        return idx + 1;
    }

    function idToIdx(uint256 id) internal pure returns (uint256) {
        return id - 1;
    }
}