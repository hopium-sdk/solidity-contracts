// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfRouter.sol";

error EmptyCode();
error ZeroOwner();
error CodeAlreadyExists();
error CodeNotFound();

abstract contract Utils {
    /// @dev Converts an ASCII string to uppercase.
    function _toUpper(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory bUpper = new bytes(bStr.length);

        for (uint256 i = 0; i < bStr.length; ) {
            // lowercase letters a–z => 97–122
            if (bStr[i] >= 0x61 && bStr[i] <= 0x7A) {
                bUpper[i] = bytes1(uint8(bStr[i]) - 32);
            } else {
                bUpper[i] = bStr[i];
            }
            unchecked {
                ++i;
            }
        }
        return string(bUpper);
    }
}

contract EtfAffiliate is ImDirectory, ImEtfRouter, Utils {
    constructor(address _directory) ImDirectory(_directory) {}

    event AffiliateAdded(string code, address owner);
    event AffiliateFeeTransferred(string code, address owner, uint256 ethAmount);

    mapping(string => address) private _codeToOwner;

    /// @notice Create a new affiliate code for a specified owner.
    function createAffiliate(string calldata code, address owner) external {
        if (bytes(code).length == 0) revert EmptyCode();
        if (owner == address(0)) revert ZeroOwner();

        string memory upperCode = _toUpper(code);

        if (_codeToOwner[upperCode] != address(0)) revert CodeAlreadyExists();

        _codeToOwner[upperCode] = owner;
        emit AffiliateAdded(upperCode, owner);
    }

    /// @notice Emit a fee transfer event for a valid affiliate code.
    function emitFeeTransferredEvent(string calldata code, uint256 ethAmount)
        external
        onlyEtfRouter
    {
        string memory upperCode = _toUpper(code);
        address owner = _codeToOwner[upperCode];
        if (owner == address(0)) revert CodeNotFound();

        emit AffiliateFeeTransferred(upperCode, owner, ethAmount);
    }

    function getAffiliateOwner(string calldata code) external view returns (address) {
        return _codeToOwner[_toUpper(code)];
    }

    /// @notice Check if a code is already taken (case-insensitive).
    function isCodeTaken(string calldata code) external view returns (bool) {
        return _codeToOwner[_toUpper(code)] != address(0);
    }
}
