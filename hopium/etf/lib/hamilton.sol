// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library Hamilton {
    /// @dev Distribute `total` across items proportionally to `numerators`,
    /// using Hamilton/Largest Remainder. If `caps` is provided, each item
    /// is hard-capped (same unit as `total`) and leftover is re-allocated.
    /// - Deterministic tie-breaking by lower index.
    /// - Returns an array `out` s.t. sum(out) == min(total, sum(caps or INF)).
    /// @dev Distribute `total` across items proportionally to `numerators`,
    /// using Hamilton/Largest Remainder. If `caps` is provided (same length),
    /// each item is capped (same units as `total`) and leftover is re-allocated.
    /// Deterministic tie-break by lower index. Sum(out) == min(total, sum(caps or INF)).
    function distribute(
        uint256[] memory numerators,
        uint256 total,
        uint256[] memory caps
    ) internal pure returns (uint256[] memory out) {
        uint256 n = numerators.length;
        out = new uint256[](n);
        if (n == 0 || total == 0) return out;

        uint256 sumNum;
        for (uint256 i = 0; i < n; ) { sumNum += numerators[i]; unchecked { ++i; } }
        if (sumNum == 0) return out;

        bool useCaps = (caps.length == n);

        // Floor allocation + remainder capture
        uint256 acc;
        uint256[] memory rem = new uint256[](n); // in [0, sumNum)
        for (uint256 i = 0; i < n; ) {
            uint256 num = numerators[i];
            if (num == 0) { unchecked { ++i; } continue; }

            uint256 prod = num * total;
            uint256 w    = prod / sumNum;         // floor
            uint256 r    = prod - w * sumNum;     // remainder

            if (useCaps && w > caps[i]) { // respect caps on the floor pass
                w = caps[i];
                r = 0;                    // saturated → don't compete for remainder
            }

            out[i] = w;
            rem[i] = r;
            acc += w;
            unchecked { ++i; }
        }

        if (acc == total) return out;

        if (acc > total) {
            // Overshoot can happen if caps chopped floors. Trim smallest remainders first.
            uint256 over = acc - total;
            while (over != 0) {
                uint256 bestIdx = type(uint256).max;
                uint256 bestRem = type(uint256).max;
                for (uint256 i = 0; i < n; ) {
                    if (out[i] != 0 && rem[i] < bestRem) { bestRem = rem[i]; bestIdx = i; }
                    unchecked { ++i; }
                }
                if (bestIdx == type(uint256).max) break;
                out[bestIdx] -= 1;
                rem[bestIdx] = type(uint256).max; // avoid trimming same index repeatedly
                unchecked { --over; }
            }
            return out;
        }

        // acc < total → hand out remaining units to largest remainders, honoring caps
        uint256 need = total - acc;
        while (need != 0) {
            uint256 bestIdx = type(uint256).max;
            uint256 bestRem = 0;

            for (uint256 i = 0; i < n; ) {
                if (!useCaps || out[i] < caps[i]) {
                    if (rem[i] > bestRem) { bestRem = rem[i]; bestIdx = i; }
                }
                unchecked { ++i; }
            }

            if (bestIdx == type(uint256).max || bestRem == 0) {
                // No fractional winners or all capped → greedily fill first eligible indices
                for (uint256 i = 0; i < n && need != 0; ) {
                    if (!useCaps || out[i] < caps[i]) { out[i] += 1; unchecked { --need; } }
                    unchecked { ++i; }
                }
                break;
            } else {
                out[bestIdx] += 1;
                rem[bestIdx] = 0; // give others a turn on the next iteration
                unchecked { --need; }
            }
        }
        return out;
    }
}