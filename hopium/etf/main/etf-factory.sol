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
import "hopium/etf/interface/imEtfRouter.sol";

abstract contract Storage {
    mapping(uint256 => address) internal indexIdToEtfTokenAddress;
    mapping(address => uint256) internal etfTokenAddressToIndexId;
    mapping(uint256 => address) internal indexIdToEtfVaultAddress;
    mapping(uint256 => uint256) internal indexIdToTotalVolumeWeth;
    mapping(uint256 => uint256) internal indexIdToTotalVolumeUsd;
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

contract EtfFactory is ImDirectory, ImEtfTokenDeployer, ImEtfVaultDeployer, Helpers, ImActive, ImEtfRouter {
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
        etfTokenAddressToIndexId[etfTokenAddress] = indexId;

        // deploy etf vault
        address etfVaultAddress = getEtfVaultDeployer().deployEtfVault(indexId);
        indexIdToEtfVaultAddress[indexId] = etfVaultAddress;

        emit EtfDeployed(indexId, etfTokenAddress, etfVaultAddress);
    }

    function updateEtfVolume(uint256 indexId, uint256 tradeWethValue) public onlyEtfRouter {
        require(tradeWethValue > 0, "EtfFactory: trade value is zero");

        uint256 wethUsdPrice = getPriceOracle().getWethUsdPrice(); // USD per 1 WETH (1e18-scaled)
        require(wethUsdPrice > 0, "EtfFactory: WETH/USD price is zero");

        // Calculate USD value of trade: (tradeWethValue * USD per WETH) / 1e18
        uint256 tradeUsdValue = (tradeWethValue * wethUsdPrice) / 1e18;

        // Accumulate WETH and USD trade volumes for this index
        indexIdToTotalVolumeWeth[indexId] += tradeWethValue;
        indexIdToTotalVolumeUsd[indexId] += tradeUsdValue;
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

    function getIndexIdFromEtfTokenAddress(address etfTokenAddress) public view returns (uint256) {
        return etfTokenAddressToIndexId[etfTokenAddress];
    }

    function getEtfTotalVolumeWeth(uint256 indexId) public view returns (uint256) {
        return indexIdToTotalVolumeWeth[indexId];
    }

    function getEtfTotalVolumeUsd(uint256 indexId) public view returns (uint256) {    
        return indexIdToTotalVolumeUsd[indexId];
    }
}