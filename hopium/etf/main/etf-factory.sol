// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imIndexFactory.sol";
import "hopium/etf/interface/imEtfTokenDeployer.sol";
import "hopium/etf/interface/imEtfVaultDeployer.sol";
import "hopium/etf/storage/index.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hopium/standalone/interface/imPriceOracle.sol";
import "hopium/common/interface/imActive.sol";

abstract contract Storage {
    mapping(uint256 => address) internal indexIdToEtfTokenAddress;
    mapping(address => bool) internal etfTokenAddresses;
    mapping(uint256 => address) internal indexIdToEtfVaultAddress;
}

abstract contract Helpers is ImIndexFactory, ImPriceOracle, Storage {

    function _getEtfTokenAddress(uint256 indexId) internal view returns (address) {
        return indexIdToEtfTokenAddress[indexId];
    }

    function _getEtfVaultAddress(uint256 indexId) internal view returns (address) {
        return indexIdToEtfVaultAddress[indexId];
    }

    function _getEtfNavWeth(uint256 indexId) internal view returns (uint256 nav) {
        Index memory index = getIndexFactory().getIndexById(indexId);
        address vaultAddress = _getEtfVaultAddress(indexId);

        for (uint256 i = 0; i < index.holdings.length; i++) {
            address token = index.holdings[i].tokenAddress;
            uint256 balance = IERC20(token).balanceOf(vaultAddress);
            if (balance == 0) continue;

            uint256 px = getPriceOracle().getTokenWethPrice(token); // 1e18
            nav += (balance * px) / 1e18;
        }
    }

    function _getEtfNavUsd(uint256 indexId) internal view returns (uint256 navUsd) {
        uint256 navWeth = _getEtfNavWeth(indexId);
        if (navWeth == 0) return 0;

        uint256 wethUsdPrice = getPriceOracle().getWethUsdPrice(); // USD per 1 WETH (1e18-scaled)
        require(wethUsdPrice > 0, "EtfFactory: WETH/USD price is zero");

        // NAV(USD) = NAV(WETH) * USD per WETH / 1e18
        navUsd = (navWeth * wethUsdPrice) / 1e18;
    }
}

contract EtfFactory is ImDirectory, ImEtfTokenDeployer, ImEtfVaultDeployer, Helpers, ImActive {
    constructor(address _directory) ImDirectory(_directory) {}

    event EtfDeployed(
        uint256 indexed indexId,
        address etfTokenAddress,
        address etfVaultAddress
    );

    // -- Write fns --

    function createIndexAndEtf(Index calldata index) public onlyOwner onlyActive {
        // create index
        uint256 indexId = getIndexFactory().createIndex(index);

        // deploy etf token
        address etfTokenAddress = getEtfTokenDeployer().deployEtfToken(indexId, index.name, index.ticker);
        indexIdToEtfTokenAddress[indexId] = etfTokenAddress;
        etfTokenAddresses[etfTokenAddress] = true;

        // deploy etf vault
        address etfVaultAddress = getEtfVaultDeployer().deployEtfVault(indexId);
        indexIdToEtfVaultAddress[indexId] = etfVaultAddress;

        emit EtfDeployed(indexId, etfTokenAddress, etfVaultAddress);
    }

    // -- Read fns --

    function getEtfTokenAddress(uint256 indexId) public view returns (address) {
        return _getEtfTokenAddress(indexId);
    }

    function getEtfVaultAddress(uint256 indexId) public view returns (address) {
        return _getEtfVaultAddress(indexId);
    }

    function getEtfNavWeth(uint256 indexId) public view returns (uint256 nav) {
        return _getEtfNavWeth(indexId);
    }

    function getEtfNavUsd(uint256 indexId) public view returns (uint256 navUsd) {
        return _getEtfNavUsd(indexId);
    }

    function isEtfTokenAddress(address etfTokenAddress) public view returns (bool) {
        return etfTokenAddresses[etfTokenAddress];
    }
}