// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";

interface IEtfTokenDeployer {
    function deployEtfToken(uint256 indexId, string calldata name, string calldata symbol) external returns (address);
    function getEtfTokenAddress(uint256 indexId) external view returns (address);
}

abstract contract ImEtfTokenDeployer is ImDirectory {

    function getEtfTokenDeployer() internal view virtual returns (IEtfTokenDeployer) {
        return IEtfTokenDeployer(fetchFromDirectory("etf-token-deployer"));
    }
    
}