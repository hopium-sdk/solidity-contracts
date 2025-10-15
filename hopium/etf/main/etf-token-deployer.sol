// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/proxy/Clones.sol";

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/iEtfToken.sol";

abstract contract Helpers is ImDirectory {
   
    function _randomSalt() internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                block.timestamp,
                block.prevrandao, // replaces block.difficulty since 0.8.18
                msg.sender,
                gasleft()
            )
        );
    }

    error ImplNotSet();
    function _getTokenImplAddress() internal view returns (address tokenImpl) {
        tokenImpl = fetchFromDirectory("etf-token-impl");
        if (tokenImpl == address(0)) revert ImplNotSet();
    }
}

/// @notice Factory that mints minimal-proxy clones of EtfToken (EIP-1167)
contract EtfTokenDeployer is ImDirectory, Helpers {
    using Clones for address;

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Deploy a new ETF token clone with per-clone name/symbol
    function deployEtfToken(uint256 indexId, string calldata name, string calldata symbol) external returns (address proxy) {
        // Create deterministic clone (CREATE2). Reverts if already deployed for same salt.
        proxy = Clones.cloneDeterministic(_getTokenImplAddress(), _randomSalt());

        // Initialize with per-clone params
        IEtfToken(proxy).initialize(indexId, name, symbol, address(Directory));
    }

}
