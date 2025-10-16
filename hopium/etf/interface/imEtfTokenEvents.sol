// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";

interface IEtfTokenEvents {
    function emitTransferEvent(uint256 etfId, address fromAddress, address toAddress, uint256 transferAmount) external;
}

abstract contract ImEtfTokenEvents is ImDirectory {

    function getEtfTokenEvents() internal view virtual returns (IEtfTokenEvents) {
        return IEtfTokenEvents(fetchFromDirectory("etf-token-events"));
    }
    
}