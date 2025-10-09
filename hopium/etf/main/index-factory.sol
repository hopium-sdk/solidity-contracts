// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/storage/index.sol";
import "hopium/common/storage/bips.sol";
import "hopium/common/utils/id-idx.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/common/interface/imActive.sol";

/// @notice Storage keeps created indexes and mapping tables
abstract contract Storage {
    Index[] internal createdIndexes;

    // map tickerHash (bytes32) → indexId (1-based)
    mapping(bytes32 => uint256) internal indexTickerHashToId;

    // map indexHash → indexId (1-based)
    mapping(bytes32 => uint256) internal indexHashToId;
}

/// @notice Utils: sorting & hashing helpers
abstract contract Utils is IdIdxUtils {
    /// @dev insertion sort by (tokenAddress, weightBips). Cheaper for small n.
    function _insertionSort(Holding[] memory a) internal pure {
        uint256 n = a.length;
        for (uint256 i = 1; i < n; ) {
            Holding memory key = a[i];
            uint256 j = i;
            while (j > 0) {
                Holding memory prev = a[j - 1];
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
    function _computeIndexHashSorted(Holding[] memory sorted) internal pure returns (bytes32) {
        // Avoid building parallel arrays; encode the struct array directly
        return keccak256(abi.encode(sorted));
    }

    /// @dev derive bytes32 key for ticker
    function _tickerKey(string calldata t) internal pure returns (bytes32) {
        return keccak256(bytes(t));
    }
}

/// @notice Validation + helpers fused for fewer passes & less memory churn
abstract contract ValidationHelpers is Storage, Utils {
    error EmptyTicker();
    error TickerExists();
    /// @dev ensure ticker is non-empty and globally unique (by bytes32 hash)
    function _validateTicker(string calldata ticker) internal view returns (bytes32 tickerHash) {
        if (bytes(ticker).length == 0) revert EmptyTicker();
        tickerHash = _tickerKey(ticker);
        if (indexTickerHashToId[tickerHash] != 0) revert TickerExists();
    }

    error NoHoldings();
    error ZeroToken();
    error ZeroWeight();
    error OverWeight();
    error NotHundred();
    error DuplicateToken();
    /// @dev copy->sort once; validate weights/duplicates in a single linear pass
    function _validateAndSort(Holding[] calldata holdings)
        internal
        pure
        returns (Holding[] memory sorted)
    {
        uint256 n = holdings.length;
        if (n == 0) revert NoHoldings();

        // Copy calldata to memory once
        sorted = new Holding[](n);
        for (uint256 i = 0; i < n; ) {
            Holding calldata h = holdings[i];
            address token = h.tokenAddress;
            uint256 w = h.weightBips;

            if (token == address(0)) revert ZeroToken();
            if (w == 0) revert ZeroWeight();
            if (w > HUNDRED_PERCENT_BIPS) revert OverWeight();

            sorted[i] = h;
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

    error IndexExists();
    /// @dev ensure the set (by canonical hash) hasn't been used yet
    function _validateIndexHashUnique(Holding[] memory sorted) internal view returns (bytes32 indexHash) {
        indexHash = _computeIndexHashSorted(sorted);
        if (indexHashToId[indexHash] != 0) revert IndexExists();
    }
}

/// @notice Factory with gas-optimized validation & events
contract IndexFactory is ImDirectory, ValidationHelpers, ImEtfFactory, ImActive {
    constructor(address _directory) ImDirectory(_directory) {}

    /// @dev lean event: all topics, constant-size; no dynamic arrays/strings in data
    event IndexCreated(uint256 indexed indexId);

    // -- Write Fns --

    function createIndex(Index calldata index) public onlyEtfFactory onlyActive returns (uint256) {
        // Validate ticker & get key
        bytes32 tHash = _validateTicker(index.ticker);

        // Validate holdings (copy, sort once, linear checks)
        Holding[] memory sorted = _validateAndSort(index.holdings);

        // Unique by canonical hash
        bytes32 iHash = _validateIndexHashUnique(sorted);

        // next 0-based position becomes a 1-based id via helper
        uint256 newIndexId = _idxToId(createdIndexes.length);
        createdIndexes.push(index);

        // register mappings
        indexTickerHashToId[tHash] = newIndexId;
        indexHashToId[iHash] = newIndexId;

        emit IndexCreated(newIndexId);
        return newIndexId;
    }

    // -- Read fns --

    function totalIndexes() external view returns (uint256) {
        return createdIndexes.length;
    }

    error InvalidId();
    function getIndexById(uint256 indexId) external view returns (Index memory) {
        if (indexId == 0 || indexId > createdIndexes.length) revert InvalidId();
        return createdIndexes[_idToIdx(indexId)];
    }

    error UnknownTicker();
    function getIndexByTicker(string calldata ticker) external view returns (Index memory) {
        bytes32 tHash = _tickerKey(ticker);
        uint256 indexId = indexTickerHashToId[tHash];
        if (indexId == 0) revert UnknownTicker();
        return createdIndexes[_idToIdx(indexId)];
    }
}
