// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";

interface IEtfFactory {
    function getEtfNavWeth(uint256 indexId) external view returns (uint256 nav);
    function updateEtfVolume(uint256 indexId, uint256 ethAmount) external;
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