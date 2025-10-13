// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/ierc20.sol";

abstract contract TransferHelpers {
    /* ----------------------------- Custom Errors ----------------------------- */
    error ZeroAmount();
    error InsufficientETH();
    error ETHSendFailed();
    error AllowanceTooLow();
    error NothingReceived();

    /* ----------------------------- Internal Helpers -------------------------- */

    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }

    function _safeApprove(address token, address spender, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }

    /* ------------------------------- ETH helpers ----------------------------- */

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert InsufficientETH();

        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert ETHSendFailed();
    }

    /* ------------------------------ Token helpers ---------------------------- */

    function _sendToken(address token, address to, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        _safeTransfer(token, to, amount);
    }

    function _receiveToken(address token, uint256 amount, address from) internal returns (uint256 received) {
        if (amount == 0) revert ZeroAmount();

        uint256 currentAllowance = IERC20(token).allowance(from, address(this));
        if (currentAllowance < amount) revert AllowanceTooLow();

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(token, from, address(this), amount);
        uint256 balAfter = IERC20(token).balanceOf(address(this));

        unchecked {
            received = balAfter - balBefore;
        }
        if (received == 0) revert NothingReceived();
    }

    function _approveMaxIfNeeded(address token, address spender, uint256 amount) internal {
        uint256 current = IERC20(token).allowance(address(this), spender);
        if (current < amount) {
            if (current != 0) _safeApprove(token, spender, 0);
            _safeApprove(token, spender, type(uint256).max);
        }
    }

    function _sendEthOrToken(address token, address to) internal {
        if (token == address(0)) {
            _sendEth(to, address(this).balance);
        } else {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) _safeTransfer(token, to, bal);
        }
    }

    function _recoverAsset(address token, address to) internal {
        _sendEthOrToken(token, to);
    }
}
