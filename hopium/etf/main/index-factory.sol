// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/storage/index.sol";
import "hopium/common/storage/bips.sol";
import "hopium/common/utils/id-idx.sol";
import "hopium/etf/interface/imEtfFactory.sol";

abstract contract Storage {
    Index[] internal createdIndexes;

    // map ticker → indexId (1-based)
    mapping(string => uint256) internal indexTickerToId;

    // map indexHash → indexId (1-based)
    mapping(bytes32 => uint256) internal indexHashToId;

}

abstract contract Utils is IdIdxUtils {
    /// @dev simple in-place sort by (tokenAddress, weight)
    function _sortHoldings(Holding[] memory h) internal pure {
        uint256 n = h.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 minIndex = i;
            for (uint256 j = i + 1; j < n; j++) {
                if (
                    (uint160(h[j].tokenAddress) < uint160(h[minIndex].tokenAddress)) ||
                    (
                        h[j].tokenAddress == h[minIndex].tokenAddress &&
                        h[j].weightBips < h[minIndex].weightBips
                    )
                ) {
                    minIndex = j;
                }
            }
            if (minIndex != i) {
                (h[i], h[minIndex]) = (h[minIndex], h[i]);
            }
        }
    }

    /// @dev compute canonical, order-insensitive hash for token-weight pairs
    function _computeIndexHash(Holding[] calldata holdings)
        internal
        pure
        returns (bytes32)
    {
        uint256 n = holdings.length;
        Holding[] memory h = new Holding[](n);
        for (uint256 i = 0; i < n; i++) h[i] = holdings[i];

        _sortHoldings(h);

        address[] memory tokens = new address[](n);
        uint16[] memory weights = new uint16[](n);
        for (uint256 i = 0; i < n; i++) {
            tokens[i] = h[i].tokenAddress;
            weights[i] = h[i].weightBips;
        }

        return keccak256(abi.encode(tokens, weights));
    }
}

abstract contract ValidationHelpers is Storage, Utils {
    /// @dev ensure ticker is non-empty and globally unique
    function _validateTicker(string calldata ticker) internal view {
        require(bytes(ticker).length != 0, "Empty ticker");
        require(indexTickerToId[ticker] == 0, "Ticker already exists");
    }

    /// @dev ensure all tokens are valid & unique, and weights sum to 100%
    function _validateHoldings(Holding[] calldata holdings) internal pure {
        uint256 n = holdings.length;
        require(n > 0, "No holdings");

        uint256 sumBips;

        for (uint256 i = 0; i < n; i++) {
            address tokenA = holdings[i].tokenAddress;
            require(tokenA != address(0), "Zero token address");

            uint256 w = holdings[i].weightBips;
            require(w > 0, "Zero weight");
            require(w <= HUNDRED_PERCENT_BIPS, "Weight > 100%");

            sumBips += w;

            for (uint256 j = i + 1; j < n; j++) {
                require(tokenA != holdings[j].tokenAddress, "Duplicate token in holdings");
            }
        }

        require(sumBips == HUNDRED_PERCENT_BIPS, "Weights must sum to 100%");
    }

    /// @dev ensure this index hash (token-weight set) has not been used before
    function _validateIndexHash(Holding[] calldata holdings)
        internal
        view
        returns (bytes32 indexHash)
    {
        indexHash = _computeIndexHash(holdings);
        require(indexHashToId[indexHash] == 0, "Index with same token-weight set exists");
    }
}

contract IndexFactory is ImDirectory, ValidationHelpers, ImEtfFactory {
    constructor(address _directory) ImDirectory(_directory) {}

    event IndexCreated(uint256 indexed indexId, Index index);

    // -- Write Fns --
    function createIndex(Index calldata index) public onlyEtfFactory returns (uint256) {
        _validateTicker(index.ticker);
        _validateHoldings(index.holdings);
        bytes32 indexHash = _validateIndexHash(index.holdings);

        // next 0-based position becomes a 1-based id via helper
        uint256 newIndexId = _idxToId(createdIndexes.length);
        createdIndexes.push(index);

        // register mappings
        indexTickerToId[index.ticker] = newIndexId;
        indexHashToId[indexHash] = newIndexId;

        emit IndexCreated(newIndexId, index);

        return newIndexId;
    }

    // -- Read fns --
    function totalIndexes() public view returns (uint256) {
        return createdIndexes.length;
    }

    function getIndexById(uint256 indexId) public view returns (Index memory) {
        require(indexId > 0 && indexId <= createdIndexes.length, "Invalid index id");
        return createdIndexes[_idToIdx(indexId)];
    }

    function getIndexByTicker(string calldata ticker) public view returns (Index memory) {
        uint256 indexId = indexTickerToId[ticker];
        require(indexId != 0, "Unknown ticker");
        return getIndexById(indexId);
    }
}
