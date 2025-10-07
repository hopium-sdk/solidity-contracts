// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract TransferHelpers {
    using SafeERC20 for IERC20;

    function _sendEth(address to, uint256 amount) internal {
        require(amount > 0, "sendEth: zero amount");
        require(address(this).balance >= amount, "sendEth: insufficient ETH");

        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "ETH send failed");
    }

    function _sendToken(address tokenAddress, address toAddress, uint256 amount) internal {
        IERC20 token = IERC20(tokenAddress);
        require(amount > 0, "sendToken: zero amount");

        token.safeTransfer(toAddress, amount);
    }

    function _receiveToken(address tokenAddress, uint256 amount, address fromAddress) internal returns (uint256) {
        IERC20 token = IERC20(tokenAddress);
        require(amount > 0, "receiveToken: zero amount");
        require(token.allowance(fromAddress, address(this)) >= amount, "receiveToken: allowance is less than amount");

        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(fromAddress, address(this), amount);
        uint256 balAfter = token.balanceOf(address(this));

        uint256 received = balAfter - balBefore;
        require(received > 0, "receiveToken: nothing received");

        return received;
    }

    function _approveMaxIfNeeded(address tokenAddress, address spender, uint256 amount) internal {
        IERC20 token = IERC20(tokenAddress);
        uint256 current = token.allowance(address(this), spender);
        if (current < amount) {
            if (current != 0) {
                token.approve(spender, 0);
            }
            token.approve(spender, type(uint256).max);
        }
    }

    function _withdraw(address tokenAddress, address toAddress) internal {
        if(tokenAddress == address(0)) {
            _sendEth(toAddress, address(this).balance);
        } else {
            _sendToken(tokenAddress, toAddress, IERC20(tokenAddress).balanceOf(address(this)));
        }
    }
}