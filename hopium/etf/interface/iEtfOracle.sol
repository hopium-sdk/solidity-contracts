// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/etf/types/etf.sol";
import "hopium/etf/types/snapshot.sol";

interface IEtfOracle {
   function getEtfWethPrice(uint256 etfId) external view returns (uint256);
   function getEtfPrice(uint256 etfId) external view returns (uint256 wethPrice18, uint256 usdPrice18);
   function snapshotVaultUnchecked(Etf memory etf, address vaultAddress) external view returns (Snapshot[] memory s, uint256 etfTvlWeth);
}