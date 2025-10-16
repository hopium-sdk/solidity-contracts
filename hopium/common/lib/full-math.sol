// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library FullMath {
    /// @dev Full-precision multiply-divide: floor(a * b / denominator)
    ///      Reverts if denominator == 0 or the result overflows uint256.
    /// @notice Based on Uniswap v3’s FullMath.mulDiv().
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            uint256 prod0; // Least-significant 256 bits
            uint256 prod1; // Most-significant 256 bits
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // No overflow: do simple division
            if (prod1 == 0) return prod0 / denominator;

            require(denominator > prod1, "mulDiv overflow");

            ///////////////////////////////////////////////
            //  Make division exact  (subtract remainder)
            ///////////////////////////////////////////////
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            ///////////////////////////////////////////////
            //  Factor powers of two out of denominator
            ///////////////////////////////////////////////
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Combine high and low products
            prod0 |= prod1 * twos;

            ///////////////////////////////////////////////
            //  Compute modular inverse of denominator mod 2²⁵⁶
            ///////////////////////////////////////////////
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // inverse mod 2⁸
            inv *= 2 - denominator * inv; // mod 2¹⁶
            inv *= 2 - denominator * inv; // mod 2³²
            inv *= 2 - denominator * inv; // mod 2⁶⁴
            inv *= 2 - denominator * inv; // mod 2¹²⁸
            inv *= 2 - denominator * inv; // mod 2²⁵⁶

            ///////////////////////////////////////////////
            //  Multiply by modular inverse to finish division
            ///////////////////////////////////////////////
            result = prod0 * inv;
            return result;
        }
    }
}