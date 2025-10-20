// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";

interface IEtfRouter {
    function mintEtfTokens(uint256 etfId, address receiver) external payable;
}

abstract contract ImEtfRouter is ImDirectory {

    function getEtfRouter() internal view virtual returns (IEtfRouter) {
        return IEtfRouter(fetchFromDirectory("etf-router"));
    }

    modifier onlyEtfRouter() {
        require(msg.sender == fetchFromDirectory("etf-router"), "msg.sender is not etf router");
        _;
    }
}