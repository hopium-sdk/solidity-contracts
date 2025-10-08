// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/etf/interface/imIndexPriceOracle.sol";

contract EtfTokenEvents is ImDirectory, ImEtfFactory, ImIndexPriceOracle {

    event EtfTokenTransfer(
        address indexed etfTokenAddress,
        address indexed fromAddress,
        address indexed toAddress,
        uint256 transferAmount,
        uint256 indexWethPrice
    );

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Emits a transfer event for ETF tokens
    function emitTransferEvent(address fromAddress, address toAddress, uint256 transferAmount) external {
        address etfTokenAddress = msg.sender;
        uint256 indexId = getEtfFactory().getIndexIdFromEtfTokenAddress(etfTokenAddress);
        require(indexId != 0, "Invalid etfTokenAddress");

        uint256 indexWethPrice = getIndexPriceOracle().getIndexWethPrice(indexId);
        
        emit EtfTokenTransfer(etfTokenAddress, fromAddress, toAddress, transferAmount, indexWethPrice);
    }
}
