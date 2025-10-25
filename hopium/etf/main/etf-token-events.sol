// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfOracle.sol";

contract EtfTokenEvents is ImDirectory, ImEtfOracle {

    event EtfTokenTransfer(
        uint256 etfId,
        address indexed fromAddress,
        address indexed toAddress,
        uint256 transferAmount,
        uint256 etfWethPrice,
        uint256 etfUsdPrice,
        uint256 totalSupply
    );

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Emits a transfer event for ETF tokens
    function emitTransferEvent(uint256 etfId, address fromAddress, address toAddress, uint256 transferAmount, uint256 totalSupply) external {

        (uint256 etfWethPrice, uint256 etfUsdPrice) = getEtfOracle().getEtfPrice(etfId);

        emit EtfTokenTransfer(etfId, fromAddress, toAddress, transferAmount, etfWethPrice, etfUsdPrice, totalSupply);
    }
}
