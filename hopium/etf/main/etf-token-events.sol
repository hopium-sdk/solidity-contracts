// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";

contract EtfTokenEvents is ImDirectory, ImEtfFactory {

    event EtfTokenTransfer(
        address indexed etfTokenAddress,
        address indexed fromAddress,
        address indexed toAddress,
        uint256 amount
    );

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Emits a transfer event for ETF tokens
    function emitTransferEvent(address fromAddress, address toAddress, uint256 amount) external {
        address etfTokenAddress = msg.sender;
        require(getEtfFactory().isEtfTokenAddress(etfTokenAddress), "Invalid etfTokenAddress");

        emit EtfTokenTransfer(etfTokenAddress, fromAddress, toAddress, amount);
    }
}
