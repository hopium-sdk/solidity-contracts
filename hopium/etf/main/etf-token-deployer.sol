// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/proxy/Clones.sol";

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/etf/interface/iEtfToken.sol";

error ImplNotSet();

abstract contract Helpers is ImDirectory {
    /// @dev Deterministic salt; include indexId to keep it stable per index.
    /// You can also add name/symbol if you want unique addresses per symbol.
    function _salt(uint256 indexId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ETF_TOKEN", indexId));
    }

    /// @dev Fetch the token implementation (logic) from Directory
    function getTokenImpl() internal view returns (address) {
        address tokenImpl = fetchFromDirectory("etf-token-impl");
        if (tokenImpl == address(0)) revert ImplNotSet();

        return tokenImpl;
    }
}

/// @notice Factory that mints minimal-proxy clones of EtfToken (EIP-1167)
contract EtfTokenDeployer is ImDirectory, ImEtfFactory, Helpers {
    using Clones for address;

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Deploy a new ETF token clone with per-clone name/symbol
    function deployEtfToken(uint256 indexId, string calldata name, string calldata symbol) external onlyEtfFactory returns (address proxy) {
        address tokenImpl = getTokenImpl();

        // Create deterministic clone (CREATE2). Reverts if already deployed for same salt.
        proxy = Clones.cloneDeterministic(tokenImpl, _salt(indexId));

        // Initialize with per-clone params
        IEtfToken(proxy).initialize(name, symbol, address(Directory));
    }
}
