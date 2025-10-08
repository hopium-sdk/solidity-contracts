// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/access/Ownable.sol";

contract Directory is Ownable {
    constructor() Ownable(msg.sender) {}

    mapping(string => address) directory;

    struct KeyValue {
        string key;
        address value;
    }

    function updateDirectory(KeyValue[] memory _keyValue) public onlyOwner {
        for (uint256 i = 0; i < _keyValue.length; i++) {
                directory[_keyValue[i].key] = _keyValue[i].value;
        }
    }

    function fetchFromDirectory(string memory _key) public view returns (address) {
        address value = directory[_key];
        require(value != address(0), "fetchFromDirectory: Address not set");
        return value;
    }
}
