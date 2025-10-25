// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/types/etf.sol";

interface IEtfFactory {
    function updateEtfVolume(uint256 etfId, uint256 ethAmount) external;

    //read
    //data
    function getEtfById(uint256 etfId) external view returns (Etf memory);
    function getEtfTokenAddress(uint256 etfId) external view returns (address);
    function getEtfVaultAddress(uint256 etfId) external view returns (address);
    function getEtfByIdAndAddresses(uint256 etfId) external view returns (Etf memory etf, address tokenAddress, address vaultAddress);
    function getEtfByIdAndVault(uint256 etfId) external view returns (Etf memory etf, address vaultAddress);

    //events
    function emitVaultBalanceEvent(uint256 etfId) external;
}

abstract contract ImEtfFactory is ImDirectory {

    function getEtfFactory() internal view virtual returns (IEtfFactory) {
        return IEtfFactory(fetchFromDirectory("etf-factory"));
    }

    modifier onlyEtfFactory() {
        require(msg.sender == fetchFromDirectory("etf-factory"), "msg.sender is not etf factory");
        _;
    }
}