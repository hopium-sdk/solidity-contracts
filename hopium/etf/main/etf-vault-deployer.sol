// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/iEtfVault.sol";


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
    function _getVaultImplAddress() internal view returns (address vaultImpl) {
        vaultImpl = fetchFromDirectory("etf-vault-impl");
        if (vaultImpl == address(0)) revert ImplNotSet();
    }
}

/// @notice Factory that mints minimal-proxy clones of EtfVault (EIP-1167)
contract EtfVaultDeployer is ImDirectory, Helpers {
    using Clones for address;

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Deploys a new EtfVault clone and initializes it with current Directory
    function deployEtfVault() external returns (address proxy) {
        proxy = Clones.cloneDeterministic(_getVaultImplAddress(), _randomSalt());
        
        IEtfVault(proxy).initialize(address(Directory));
    }
}
