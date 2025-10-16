// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface-ext/iErc20.sol";

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}