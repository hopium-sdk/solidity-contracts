// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/proxy/Clones.sol";

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/etf/interface/iEtfToken.sol";

abstract contract Helpers is ImDirectory {
    /// @dev Deterministic salt; include indexId to keep it stable per index.
    /// You can also add name/symbol if you want unique addresses per symbol.
    function _salt(uint256 indexId) internal pure returns (bytes32) {
        return bytes32(indexId);
    }

    error ImplNotSet();
    function _getTokenImplAddress() internal view returns (address tokenImpl) {
        tokenImpl = fetchFromDirectory("etf-token-impl");
        if (tokenImpl == address(0)) revert ImplNotSet();
    }
}

/// @notice Factory that mints minimal-proxy clones of EtfToken (EIP-1167)
contract EtfTokenDeployer is ImDirectory, ImEtfFactory, Helpers {
    using Clones for address;

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Deploy a new ETF token clone with per-clone name/symbol
    function deployEtfToken(uint256 indexId, string calldata name, string calldata symbol) external onlyEtfFactory returns (address proxy) {
        // Create deterministic clone (CREATE2). Reverts if already deployed for same salt.
        proxy = Clones.cloneDeterministic(_getTokenImplAddress(), _salt(indexId));

        // Initialize with per-clone params
        IEtfToken(proxy).initialize(indexId, name, symbol, address(Directory));
    }

    /// @notice Predicts the ETF token address for given indexId.
    /// @dev Returns address(0) if it hasn't been deployed yet.
    function getEtfTokenAddress(uint256 indexId) external view returns (address tokenAddr) {
        tokenAddr = Clones.predictDeterministicAddress(_getTokenImplAddress(), _salt(indexId), address(this));

        // Return zero address if no contract code deployed yet
        if (tokenAddr.code.length == 0) {
            tokenAddr = address(0);
        }
    }

}
