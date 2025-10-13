// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Helpers to compute the arithmetic mean tick from Uniswap V3 tick cumulatives
library TwapTick {
    /// @notice Compute mean tick from a cumulative delta and a secondsAgo window.
    /// @dev Rounds toward negative infinity, matching Uniswap periphery behavior.
    /// @param tickCumulativesDelta tickCumulatives[end] - tickCumulatives[start]
    /// @param secondsAgo The window length (must be > 0)
    /// @return meanTick Arithmetic mean tick over the window
    function meanTickFromDelta(int56 tickCumulativesDelta, uint32 secondsAgo)
        internal
        pure
        returns (int24 meanTick)
    {
        require(secondsAgo != 0, "BP");

        // Cast secondsAgo to a signed type for mixed signed/unsigned ops
        int56 secondsAgoSigned = int56(int32(secondsAgo));

        // Truncate toward zero first
        int56 q = tickCumulativesDelta / secondsAgoSigned;
        int56 r = tickCumulativesDelta % secondsAgoSigned;

        meanTick = int24(q);

        // Adjust to round toward -infinity
        if (tickCumulativesDelta < 0 && r != 0) {
            unchecked { meanTick -= 1; }
        }
    }

    /// @notice Convenience overload: compute mean tick from start/end cumulatives.
    function meanTickFromCumulatives(int56 tickCumulativeStart, int56 tickCumulativeEnd, uint32 secondsAgo)
        internal
        pure
        returns (int24)
    {
        return meanTickFromDelta(tickCumulativeEnd - tickCumulativeStart, secondsAgo);
    }
}
