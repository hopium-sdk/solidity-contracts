// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";

interface IEtfTokenDeployer {
    function deployEtfToken(uint256 indexId, string calldata name, string calldata symbol) external returns (address);
}

abstract contract ImEtfTokenDeployer is ImDirectory {

    function getEtfTokenDeployer() internal view virtual returns (IEtfTokenDeployer) {
        return IEtfTokenDeployer(fetchFromDirectory("etf-token-deployer"));
    }

     modifier onlyEtfTokenDeployer() {
        require(msg.sender == fetchFromDirectory("etf-token-deployer"), "msg.sender is not etf token deployer");
        _;
    }
    
}