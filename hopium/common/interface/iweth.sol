// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/ierc20.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}