// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

// Constants for “infinite” style approvals
uint160 constant PERMIT2_MAX_AMOUNT = type(uint160).max;
uint48  constant PERMIT2_MAX_EXPIRY = type(uint48).max;

error BadToken();
abstract contract ImPermit2 {

    function _approveMaxIfNeededPermit2(
        address permit2Addr,
        address token,
        address spender,
        uint160 amount
    ) internal {
        if (token == address(0) || spender == address(0)) revert BadToken();

        // 2) Permit2 internal allowance (owner=this, spender=`spender`)
        (uint160 currentAmt, uint48 expiry, ) = IPermit2(permit2Addr).allowance(address(this), token, spender);

        bool amountOk = (currentAmt >= amount);

        // Expired if nonzero expiry and already passed; Permit2 may return 0 for “unset”
        bool isExpired = (expiry != 0 && expiry <= block.timestamp);

        if (!amountOk || isExpired) {
            IPermit2(permit2Addr).approve(token, spender, PERMIT2_MAX_AMOUNT, PERMIT2_MAX_EXPIRY);
        }
    }
}