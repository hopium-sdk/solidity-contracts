// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/etf/interface/iEtfVault.sol";

error ImplNotSet();

abstract contract Helpers is ImDirectory {
    /// @dev Deterministic salt per indexId for CREATE2 clones (optional but useful)
    function _salt(uint256 indexId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ETF_VAULT", indexId));
    }

    function getVaultImpl() internal view returns (address) {
        address vaultImpl =  fetchFromDirectory("etf-vault-impl");
        if (vaultImpl == address(0)) revert ImplNotSet();
        
        return vaultImpl;
    }
}

/// @notice Factory that mints minimal-proxy clones of EtfVault (EIP-1167)
contract EtfVaultDeployer is ImEtfFactory, Helpers {
    using Clones for address;

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Deploys a new EtfVault clone and initializes it with current Directory
    function deployEtfVault(uint256 indexId) external onlyEtfFactory returns (address proxy) {
        address vaultImpl = getVaultImpl();

        proxy = Clones.cloneDeterministic(vaultImpl, _salt(indexId));
        
        IEtfVault(proxy).initialize(address(Directory));
    }
}
