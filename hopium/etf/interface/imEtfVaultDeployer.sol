// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";

interface IEtfVaultDeployer {
   function deployEtfVault(uint256 indexId) external returns (address);
}

abstract contract ImEtfVaultDeployer is ImDirectory {

    function getEtfVaultDeployer() internal view virtual returns (IEtfVaultDeployer) {
        return IEtfVaultDeployer(fetchFromDirectory("etf-vault-deployer"));
    }

    modifier onlyEtfVaultDeployer() {
        require(msg.sender == fetchFromDirectory("etf-vault-deployer"), "msg.sender is not etf vault deployer");
        _;
    }
    
}