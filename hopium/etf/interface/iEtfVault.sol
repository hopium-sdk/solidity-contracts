// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IEtfVault{
   function withdrawToken(address tokenAddress, uint256 amount, address receiver) external;
}
