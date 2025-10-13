// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "hopium/common/interface/iweth.sol";

library WETH {
    error InsufficientETH();
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
}