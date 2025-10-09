// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/etf/interface/imEtfTokenDeployer.sol";
import "hopium/etf/interface/imEtfVaultDeployer.sol";

abstract contract EtfAddressesHelpers is ImEtfTokenDeployer, ImEtfVaultDeployer {

    function _getEtfTokenAddress(uint256 indexId) internal view returns (address) {
        return getEtfTokenDeployer().getEtfTokenAddress(indexId);
    }

    function _getEtfVaultAddress(uint256 indexId) internal view returns (address) {
        return getEtfVaultDeployer().getEtfVaultAddress(indexId);
    }

}