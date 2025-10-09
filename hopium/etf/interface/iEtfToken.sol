// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IEtfToken {
   function initialize(uint256 indexId_, string memory name_, string memory symbol_, address directory_) external;
   function mint(address to, uint256 amount) external;
   function burn(address from, uint256 amount) external;
}
