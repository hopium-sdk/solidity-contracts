// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/types/etf.sol";
import "hopium/uniswap/interface/imPoolFinder.sol";
import "hopium/common/types/bips.sol";
import "hopium/common/lib/ididx.sol";
import "hopium/etf/interface/imEtfTokenDeployer.sol";
import "hopium/etf/interface/imEtfVaultDeployer.sol";
import "hopium/etf/interface/imEtfRouter.sol";
import "hopium/uniswap/interface/imUniswapOracle.sol";

abstract contract Storage {
    uint256 internal immutable WAD = 1e18;
    address public immutable WETH_ADDRESS;

    Etf[] internal createdEtfs;

    mapping(bytes32 => uint256) internal etfTickerHashToId;
    mapping(bytes32 => uint256) internal etfAssetsHashToId;

    mapping(uint256 => address) internal etfIdToEtfTokens;
    mapping(uint256 => address) internal etfIdToEtfVaults;
    mapping(uint256 => uint256) internal etfIdToTotalVolumeWeth;
    mapping(uint256 => uint256) internal etfIdToTotalVolumeUsd;

    event EtfDeployed(uint256 indexed etfId, Etf etf, address etfTokenAddress, address etfVaultAddress);
}

/// @notice Validation + helpers fused for fewer passes & less memory churn
abstract contract EtfCreationHelpers is Storage, ImPoolFinder {
    /// @dev insertion sort by (tokenAddress, weightBips). Cheaper for small n.
    function _insertionSort(Asset[] memory a) internal pure {
        uint256 n = a.length;
        for (uint256 i = 1; i < n; ) {
            Asset memory key = a[i];
            uint256 j = i;
            while (j > 0) {
                Asset memory prev = a[j - 1];
                // order by address, then by weight
                if (prev.tokenAddress < key.tokenAddress || 
                   (prev.tokenAddress == key.tokenAddress && prev.weightBips <= key.weightBips)) {
                    break;
                }
                a[j] = prev;
                unchecked { --j; }
            }
            a[j] = key;
            unchecked { ++i; }
        }
    }

    /// @dev canonical, order-insensitive hash for token-weight pairs from a *sorted* array
    function _computeEtfAssetsHashSorted(Asset[] memory sorted) internal pure returns (bytes32) {
        // Avoid building parallel arrays; encode the struct array directly
        return keccak256(abi.encode(sorted));
    }

    /// @dev derive bytes32 key for ticker
    function _tickerKey(string calldata t) internal pure returns (bytes32) {
        return keccak256(bytes(t));
    }

    error EmptyTicker();
    error TickerExists();
    /// @dev ensure ticker is non-empty and globally unique (by bytes32 hash)
    function _validateTicker(string calldata ticker) internal view returns (bytes32 tickerHash) {
        if (bytes(ticker).length == 0) revert EmptyTicker();
        tickerHash = _tickerKey(ticker);
        if (etfTickerHashToId[tickerHash] != 0) revert TickerExists();
    }

    error NoAssets();
    error ZeroToken();
    error ZeroWeight();
    error OverWeight();
    error NotHundred();
    error DuplicateToken();
    error NoPoolFound();
    /// @dev copy->sort once; validate weights/duplicates in a single linear pass
    function _validateAndSort(Asset[] calldata assets)
        internal
        returns (Asset[] memory sorted)
    {
        uint256 n = assets.length;
        if (n == 0) revert NoAssets();

        // Copy calldata to memory once
        sorted = new Asset[](n);
        for (uint256 i = 0; i < n; ) {
            Asset calldata a = assets[i];
            address token = a.tokenAddress;
            uint256 w = a.weightBips;

            if (token != WETH_ADDRESS) {
                Pool memory pool = getPoolFinder().getBestWethPoolAndForceUpdate(token);
                if (pool.poolAddress == address(0)) revert NoPoolFound();
            }

            if (token == address(0)) revert ZeroToken();
            if (w == 0) revert ZeroWeight();
            if (w > HUNDRED_PERCENT_BIPS) revert OverWeight();

            sorted[i] = a;
            unchecked { ++i; }
        }

        // Sort in-place
        _insertionSort(sorted);

        // Single pass: check duplicates + sum to 100%
        uint256 sum;
        for (uint256 i = 0; i < n; ) {
            if (i > 0 && sorted[i - 1].tokenAddress == sorted[i].tokenAddress) {
                revert DuplicateToken();
            }
            sum += sorted[i].weightBips;
            unchecked { ++i; }
        }
        if (sum != HUNDRED_PERCENT_BIPS) revert NotHundred();
    }

    error EtfExists();
    /// @dev ensure the set (by canonical hash) hasn't been used yet
    function _validateEtfAssetsHashUnique(Asset[] memory sorted) internal view returns (bytes32 etfAssetsHash) {
        etfAssetsHash = _computeEtfAssetsHashSorted(sorted);
        if (etfAssetsHashToId[etfAssetsHash] != 0) revert EtfExists();
    }
}

abstract contract Helpers is EtfCreationHelpers  {
    function _createEtf(Etf calldata etf) internal returns (uint256) {
        // Validate ticker & get key
        bytes32 tickerHash = _validateTicker(etf.ticker);

        // Validate holdings (copy, sort once, linear checks)
        Asset[] memory sorted = _validateAndSort(etf.assets);

        // Unique by canonical hash
        bytes32 assetsHash = _validateEtfAssetsHashUnique(sorted);

        // next 0-based position becomes a 1-based id via helper
        uint256 etfId = IdIdx.idxToId(createdEtfs.length);
        createdEtfs.push(etf);

        // register mappings
        etfTickerHashToId[tickerHash] = etfId;
        etfAssetsHashToId[assetsHash] = etfId;

        return etfId;
    }
}

contract EtfFactory is ImDirectory, Helpers, ImEtfTokenDeployer, ImEtfVaultDeployer, ImEtfRouter, ImUniswapOracle {
    constructor(address _directory,  address _wethAddress) ImDirectory(_directory) {
        WETH_ADDRESS = _wethAddress;
    }

    // -- Write fns --

    function createEtf(Etf calldata etf) external onlyOwner returns (uint256) {
        //create etf
        uint256 etfId = _createEtf(etf);

        // deploy etf token
        address etfTokenAddress = getEtfTokenDeployer().deployEtfToken(etfId, etf.name, etf.ticker);

        // deploy etf vault
        address etfVaultAddress = getEtfVaultDeployer().deployEtfVault();

        etfIdToEtfTokens[etfId] = etfTokenAddress;
        etfIdToEtfVaults[etfId] = etfVaultAddress;

        emit EtfDeployed(etfId, etf, etfTokenAddress, etfVaultAddress);

        return etfId;
    }

    error ZeroTradeValue();
    error ZeroWethUsdPrice();
    function updateEtfVolume(uint256 etfId, uint256 ethAmount) public onlyEtfRouter {
        if (ethAmount == 0) revert ZeroTradeValue();

        uint256 wethUsd = getUniswapOracle().getWethUsdPrice(); // 1e18
        if (wethUsd == 0) revert ZeroWethUsdPrice();

        uint256 amountUsd = (ethAmount * wethUsd) / WAD;

        etfIdToTotalVolumeWeth[etfId] += ethAmount;
        etfIdToTotalVolumeUsd[etfId] += amountUsd;
    }

    // -- Read fns --

    error InvalidId();
    function getEtfById(uint256 etfId) public view returns (Etf memory) {
        if (etfId == 0 || etfId > createdEtfs.length) revert InvalidId();
        return createdEtfs[IdIdx.idToIdx(etfId)];
    }

    error InvalidAddress();
    function getEtfTokenAddress(uint256 etfId) public view returns (address tokenAddress) {
        tokenAddress = etfIdToEtfTokens[etfId];
        if (tokenAddress == address(0)) revert InvalidAddress();
    }

    function getEtfVaultAddress(uint256 etfId) public view returns (address vaultAddress) {
        vaultAddress = etfIdToEtfVaults[etfId];
        if (vaultAddress == address(0)) revert InvalidAddress();
    }

    function getEtfByIdAndAddresses(uint256 etfId) external view returns (Etf memory etf, address tokenAddress, address vaultAddress) {
        etf = getEtfById(etfId);
        tokenAddress = getEtfTokenAddress(etfId);
        vaultAddress = getEtfVaultAddress(etfId);
    }

    function getEtfByIdAndVault(uint256 etfId) external view returns (Etf memory etf, address vaultAddress) {
        etf = getEtfById(etfId);
        vaultAddress = getEtfVaultAddress(etfId);
    }

    function getEtfTotalVolume(uint256 etfId) external view returns (uint256 volWeth, uint256 volUsd) {
        volWeth = etfIdToTotalVolumeWeth[etfId];
        volUsd = etfIdToTotalVolumeUsd[etfId];
    }
}