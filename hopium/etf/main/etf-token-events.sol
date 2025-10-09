// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imIndexPriceOracle.sol";

contract EtfTokenEvents is ImDirectory, ImIndexPriceOracle {

    event EtfTokenTransfer(
        address indexed etfTokenAddress,
        address indexed fromAddress,
        address indexed toAddress,
        uint256 transferAmount,
        uint256 indexWethPrice
    );

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Emits a transfer event for ETF tokens
    function emitTransferEvent(uint256 indexId, address fromAddress, address toAddress, uint256 transferAmount) external {

        uint256 indexWethPrice = getIndexPriceOracle().getIndexWethPrice(indexId);

        emit EtfTokenTransfer(msg.sender, fromAddress, toAddress, transferAmount, indexWethPrice);
    }
}
