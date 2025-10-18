// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfOracle.sol";

contract EtfTokenEvents is ImDirectory, ImEtfOracle {

    event EtfTokenTransfer(
        address indexed etfTokenAddress,
        address indexed fromAddress,
        address indexed toAddress,
        uint256 transferAmount,
        uint256 etfWethPrice,
        uint256 etfUsdPrice
    );

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Emits a transfer event for ETF tokens
    function emitTransferEvent(uint256 etfId, address fromAddress, address toAddress, uint256 transferAmount) external {

        (uint256 etfWethPrice, uint256 etfUsdPrice) = getEtfOracle().getEtfPrice(etfId);

        emit EtfTokenTransfer(msg.sender, fromAddress, toAddress, transferAmount, etfWethPrice, etfUsdPrice);
    }
}
