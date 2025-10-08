// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";

interface IEtfFactory {
    function getEtfTokenAddress(uint256 indexId) external view returns (address);
    function getEtfVaultAddress(uint256 indexId) external view returns (address);
    function getEtfNavWeth(uint256 indexId) external view returns (uint256 nav);
    function isEtfTokenAddress(address etfTokenAddress) external view returns (bool);
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