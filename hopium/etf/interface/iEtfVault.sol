// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IEtfVault{
   function redeem(address tokenAddress, uint256 amount, address receiver) external;
}
