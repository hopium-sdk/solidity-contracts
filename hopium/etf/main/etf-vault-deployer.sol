// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/etf/interface/imEtfRouter.sol";

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

library SafeERC20 {
    
    error SafeERC20FailedOperation(address token);

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            let success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            // bubble errors
            if iszero(success) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            returnSize := returndatasize()
            returnValue := mload(0)
        }

        if (returnSize == 0 ? address(token).code.length == 0 : returnValue != 1) {
            revert SafeERC20FailedOperation(address(token));
        }
    }
}

contract TransferHelpers {
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

    function _sendEthOrToken(address tokenAddress, address toAddress) internal {
        if(tokenAddress == address(0)) {
            _sendEth(toAddress, address(this).balance);
        } else {
            _sendToken(tokenAddress, toAddress, IERC20(tokenAddress).balanceOf(address(this)));
        }
    }

    function _recoverAsset(address tokenAddress, address toAddress) internal {
        _sendEthOrToken(tokenAddress, toAddress);
    }
}

/// @notice Etf Vault contract
contract EtfVault is ImEtfRouter, TransferHelpers {

    constructor(address _directory) ImDirectory(_directory) {}

    function redeem(address tokenAddress, uint256 amount, address receiver) public onlyEtfRouter {
        _sendToken(tokenAddress, receiver, amount);
    }

    function recoverAsset(address tokenAddress, address toAddress) public onlyOwner {
        _recoverAsset(tokenAddress, toAddress);
    }
}

/// @notice Factory that deploys Etf Vault
contract EtfVaultDeployer is ImDirectory, ImEtfFactory {

    constructor(address _directory) ImDirectory(_directory) {}

    event EtfVaultDeployed(
        uint256 indexed indexId,
        address vaultAddress
    );

    /// @notice Deploys a new ERC20 index token and returns its address
    function deployEtfVault(uint256 indexId) external onlyEtfFactory returns (address) {
        EtfVault newVault = new EtfVault(address(Directory));
        address vaultAddress = address(newVault);

        emit EtfVaultDeployed(indexId, vaultAddress);

        return vaultAddress;
    }
}
