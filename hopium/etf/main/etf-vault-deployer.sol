// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/etf/interface/iEtfVault.sol";


abstract contract Helpers is ImDirectory {
    /// @dev Deterministic salt per indexId for CREATE2 clones (optional but useful)
    function _salt(uint256 indexId) internal pure returns (bytes32) {
        return bytes32(indexId);
    }

    error ImplNotSet();
    function _getVaultImplAddress() internal view returns (address vaultImpl) {
        vaultImpl = fetchFromDirectory("etf-vault-impl");
        if (vaultImpl == address(0)) revert ImplNotSet();
    }
}

/// @notice Factory that mints minimal-proxy clones of EtfVault (EIP-1167)
contract EtfVaultDeployer is ImEtfFactory, Helpers {
    using Clones for address;

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Deploys a new EtfVault clone and initializes it with current Directory
    function deployEtfVault(uint256 indexId) external onlyEtfFactory returns (address proxy) {
        proxy = Clones.cloneDeterministic(_getVaultImplAddress(), _salt(indexId));
        
        IEtfVault(proxy).initialize(address(Directory));
    }

    function calcEtfVaultAddress(uint256 indexId) external view returns (address) {
        bytes32 salt = _salt(indexId);
        return Clones.predictDeterministicAddress(_getVaultImplAddress(), salt, address(this));
    }

    /// @notice Predicts the ETF token address for given indexId.
    /// @dev Returns address(0) if it hasn't been deployed yet.
    function getEtfVaultAddress(uint256 indexId) external view returns (address vaultAddr) {
        vaultAddr = Clones.predictDeterministicAddress(_getVaultImplAddress(), _salt(indexId), address(this));

        // Return zero address if no contract code deployed yet
        if (vaultAddr.code.length == 0) {
            vaultAddr = address(0);
        }
    }
}
