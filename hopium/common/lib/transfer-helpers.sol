// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface-ext/iErc20.sol";
import "hopium/common/interface-ext/iWeth.sol";

library TransferHelpers {
    /* ----------------------------- Custom Errors ----------------------------- */
    error ZeroAmount();
    error InsufficientETH();
    error ETHSendFailed();
    error AllowanceTooLow();
    error NothingReceived();

    /* ----------------------------- Internal Helpers -------------------------- */

    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }

    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }

    function safeApprove(address token, address spender, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    /* ------------------------------- ETH helpers ----------------------------- */

    function sendEth(address to, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert InsufficientETH();

        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert ETHSendFailed();
    }

    /* ------------------------------- WETH helpers ----------------------------- */

    function wrapETH(address wethAddress, uint256 amt) internal {
        if (address(this).balance < amt) revert InsufficientETH();
        IWETH(wethAddress).deposit{value: amt}();
    }

    error ETHSendFailure();
    function unwrapAndSendWETH(address wethAddress, uint256 amt, address payable to) internal {
        IWETH(wethAddress).withdraw(amt);
        (bool ok, ) = to.call{value: amt}("");
        if (!ok) revert ETHSendFailure();
    }

    /* ------------------------------ Token helpers ---------------------------- */

    function sendToken(address token, address to, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        safeTransfer(token, to, amount);
    }

    function receiveToken(address token, uint256 amount, address from) internal returns (uint256 received) {
        if (amount == 0) revert ZeroAmount();

        uint256 currentAllowance = IERC20(token).allowance(from, address(this));
        if (currentAllowance < amount) revert AllowanceTooLow();

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        safeTransferFrom(token, from, address(this), amount);
        uint256 balAfter = IERC20(token).balanceOf(address(this));

        unchecked {
            received = balAfter - balBefore;
        }
        if (received == 0) revert NothingReceived();
    }

    function approveMaxIfNeeded(address token, address spender, uint256 amount) internal {
        uint256 current = IERC20(token).allowance(address(this), spender);
        if (current < amount) {
            if (current != 0) safeApprove(token, spender, 0);
            safeApprove(token, spender, type(uint256).max);
        }
    }

    /* ------------------------------ ETH + Token helpers ---------------------------- */

    function sendEthOrToken(address token, address to) internal {
        if (token == address(0)) {
            sendEth(to, address(this).balance);
        } else {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) safeTransfer(token, to, bal);
        }
    }

    function recoverAsset(address token, address to) internal {
        sendEthOrToken(token, to);
    }
}
