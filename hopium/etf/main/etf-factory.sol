// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imIndexFactory.sol";
import "hopium/etf/storage/index.sol";
import "hopium/common/interface/ierc20.sol";
import "hopium/standalone/interface/imPriceOracle.sol";
import "hopium/common/interface/imActive.sol";
import "hopium/etf/interface/imEtfRouter.sol";
import "hopium/etf/utils/etf-addresses-helpers.sol";

uint256 constant WAD = 1e18;

abstract contract Storage {
    mapping(uint256 => uint256) internal indexIdToTotalVolumeWeth;
    mapping(uint256 => uint256) internal indexIdToTotalVolumeUsd;
}

error ZeroWethUsdPrice();
abstract contract Helpers is ImIndexFactory, ImPriceOracle, Storage, EtfAddressesHelpers {

    function _getEtfNavWeth(uint256 indexId) internal view returns (uint256 nav) {
        Index memory index = getIndexFactory().getIndexById(indexId);
        address vaultAddress = _getEtfVaultAddress(indexId);

        Holding[] memory holds = index.holdings;
        uint256 len = holds.length;

        IPriceOracle oracle = getPriceOracle();

        for (uint256 i; i < len; ) {
            address token = holds[i].tokenAddress;
            uint256 bal = IERC20(token).balanceOf(vaultAddress);
            if (bal != 0) {
                // only call oracle if there is a balance
                uint256 pxWeth = oracle.getTokenWethPrice(token); // 1e18
                // nav += (bal * pxWeth) / WAD;
                nav += (bal * pxWeth) / WAD; // safe if bal,pxWeth bounded; else consider mulDiv
            }
            unchecked { ++i; }
        }
    }

    function _getEtfNavUsd(uint256 indexId) internal view returns (uint256 navUsd) {
        uint256 navWeth = _getEtfNavWeth(indexId);
        if (navWeth == 0) return 0;

        uint256 wethUsd = getPriceOracle().getWethUsdPrice(); // 1e18
        if (wethUsd == 0) revert ZeroWethUsdPrice();

        navUsd = (navWeth * wethUsd) / WAD;
    }
}

contract EtfFactory is ImDirectory, Helpers, ImActive, ImEtfRouter {
    constructor(address _directory) ImDirectory(_directory) {}

    event EtfDeployed(uint256 indexed indexId, address etfTokenAddress, address etfVaultAddress);

    // -- Write fns --

    function createIndexAndEtf(Index calldata index) external onlyOwner onlyActive {
        // create index
        uint256 indexId = getIndexFactory().createIndex(index);

        // deploy etf token
        address etfTokenAddress = getEtfTokenDeployer().deployEtfToken(indexId, index.name, index.ticker);

        // deploy etf vault
        address etfVaultAddress = getEtfVaultDeployer().deployEtfVault(indexId);

        emit EtfDeployed(indexId, etfTokenAddress, etfVaultAddress);
    }

    error ZeroTradeValue();
    function updateEtfVolume(uint256 indexId, uint256 ethAmount) public onlyEtfRouter {
        if (ethAmount == 0) revert ZeroTradeValue();

        uint256 wethUsd = getPriceOracle().getWethUsdPrice(); // 1e18
        if (wethUsd == 0) revert ZeroWethUsdPrice();

        uint256 amountUsd = (ethAmount * wethUsd) / WAD;

        indexIdToTotalVolumeWeth[indexId] += ethAmount;
        indexIdToTotalVolumeUsd[indexId] += amountUsd;
    }

    // -- Read fns --

    function getEtfTokenAddress(uint256 indexId) external view returns (address) {
        return _getEtfTokenAddress(indexId);
    }

    function getEtfVaultAddress(uint256 indexId) external view returns (address) {
        return _getEtfVaultAddress(indexId);
    }

    function getEtfNavWeth(uint256 indexId) external view returns (uint256 nav) {
        return _getEtfNavWeth(indexId);
    }

    function getEtfNavUsd(uint256 indexId) external view returns (uint256 navUsd) {
        return _getEtfNavUsd(indexId);
    }

    function getEtfTotalVolumeWeth(uint256 indexId) external view returns (uint256) {
        return indexIdToTotalVolumeWeth[indexId];
    }

    function getEtfTotalVolumeUsd(uint256 indexId) external view returns (uint256) {
        return indexIdToTotalVolumeUsd[indexId];
    }
}