// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Interface used by the registry to talk to the external directory.
interface IDirectory {
    function owner() external view returns (address);
    function fetchFromDirectory(string memory _key) external view returns (address);
}

abstract contract ImDirectory {
    IDirectory public Directory;

    constructor(address _directory) {
        _setDirectory(_directory); // no modifier here
    }

    function changeDirectoryAddress(address _directory) external onlyOwner {
        _setDirectory(_directory);
    }

    function _setDirectory(address _directory) internal {
        require(_directory != address(0), "Directory cannot be zero address");
        require(_directory.code.length > 0, "Directory must be a contract");

        // Sanity check the interface
        try IDirectory(_directory).owner() returns (address) {
            Directory = IDirectory(_directory);
        } catch {
            revert("Directory address does not implement owner()");
        }
    }

    modifier onlyOwner() {
        require(msg.sender == Directory.owner(), "Caller is not the owner");
        _;
    }

    function owner() public view returns (address) {
        return Directory.owner();
    }

    function fetchFromDirectory(string memory _key) public view returns (address) {
        return Directory.fetchFromDirectory(_key);
    }
}
