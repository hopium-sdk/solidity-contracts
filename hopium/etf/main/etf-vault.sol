// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfRouter.sol";

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract TransferHelpers {

    function _sendEth(address to, uint256 amount) internal {
        require(amount > 0, "sendEth: zero amount");
        require(address(this).balance >= amount, "sendEth: insufficient ETH");
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "ETH send failed");
    }

    function _sendToken(address tokenAddress, address toAddress, uint256 amount) internal {
        require(amount > 0, "sendToken: zero amount");
        IERC20(tokenAddress).transfer(toAddress, amount);
    }

    function _sendEthOrToken(address tokenAddress, address toAddress) internal {
        if (tokenAddress == address(0)) {
            _sendEth(toAddress, address(this).balance);
        } else {
            _sendToken(tokenAddress, toAddress, IERC20(tokenAddress).balanceOf(address(this)));
        }
    }

    function _recoverAsset(address tokenAddress, address toAddress) internal {
        _sendEthOrToken(tokenAddress, toAddress);
    }
}

/// @notice Etf Vault implementation (logic). Clones delegatecall into this.
/// @dev Assumes ImEtfRouter -> ImDirectory for access control & Directory wiring.
contract EtfVault is ImEtfRouter, TransferHelpers {
    bool private _initialized;

    /// @notice Constructor runs once for the implementation only.
    /// @dev You can pass an existing Directory here; clones still call initialize().
    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice One-time initializer for clones (constructors don't run for proxies)
    function initialize(address _directory) external {
        require(!_initialized, "EtfVault: already initialized");
        _initialized = true;

        _setDirectory(_directory); // from ImDirectory (no modifier)
    }

    /// @notice Redeem underlying tokens to receiver; callable only by EtfRouter
    function redeem(address tokenAddress, uint256 amount, address receiver) external onlyEtfRouter {
        _sendToken(tokenAddress, receiver, amount);
    }

    /// @notice Owner (Directory.owner()) can recover stuck ETH/ERC20
    function recoverAsset(address tokenAddress, address toAddress) external onlyOwner {
        _recoverAsset(tokenAddress, toAddress);
    }

    receive() external payable {}
}
