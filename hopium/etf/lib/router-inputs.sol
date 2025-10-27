// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/etf/types/etf.sol";
import "hopium/etf/types/snapshot.sol";
import "hopium/uniswap/types/multiswap.sol";
import "hopium/common/types/bips.sol";
import "hopium/etf/lib/hamilton.sol";
import "hopium/common/lib/full-math.sol";

library RouterInputs {
    //----- Mint -----
    function buildMintOutputs(
        Etf memory etf,
        uint256 ethBudget,
        Snapshot[] memory snap,
        uint256 tvlWeth18
    ) internal pure returns (MultiTokenOutput[] memory buys) {
        uint256 n = etf.assets.length;
        uint256 postMintTVLWeth18 = tvlWeth18 + ethBudget;

        // Collect underweights (value deficits in WETH18)
        address[] memory uwTok = new address[](n);
        uint256[] memory uwDef = new uint256[](n);
        uint256 m;
        for (uint256 i = 0; i < n; ) {
            uint256 target = (uint256(etf.assets[i].weightBips) * postMintTVLWeth18) / HUNDRED_PERCENT_BIPS;
            uint256 cur = snap[i].tokenValueWeth18;
            if (target > cur) {
                uwTok[m] = snap[i].tokenAddress;
                uwDef[m] = target - cur;
                unchecked { ++m; }
            }
            unchecked { ++i; }
        }

        if (m == 0) {
            // Fallback: normalize target weights to 10_000 bips
            uint256[] memory numerators = new uint256[](n);
            for (uint256 i = 0; i < n; ) { numerators[i] = etf.assets[i].weightBips; unchecked { ++i; } }

            // Produce normalized weights
            uint256[] memory w = Hamilton.distribute(
                numerators,
                HUNDRED_PERCENT_BIPS,
                new uint256[](0)
            );

            buys = new MultiTokenOutput[](n);
            for (uint256 i = 0; i < n; ) {
                buys[i] = MultiTokenOutput({
                    tokenAddress: snap[i].tokenAddress,
                    weightBips: uint16(w[i])  // fits since total is 10_000
                });
                unchecked { ++i; }
            }
            return buys;
        }

        // Allocate 10,000 bips proportionally to deficits
        uint256[] memory nums = new uint256[](m);
        for (uint256 i = 0; i < m; ) { nums[i] = uwDef[i]; unchecked { ++i; } }

        // Produce normalized weights for underweights only
        uint256[] memory w2 = Hamilton.distribute(
            nums,
            HUNDRED_PERCENT_BIPS,
            new uint256[](0)
        );

        buys = new MultiTokenOutput[](m);
        for (uint256 i = 0; i < m; ) {
            buys[i] = MultiTokenOutput({
                tokenAddress: uwTok[i],
                weightBips: uint16(w2[i])
            });
            unchecked { ++i; }
        }
    }

    //----- Redeem -----
    error ZeroTvl();
    error TargetGtTvl();
    error EmptyArr();
    function buildRedeemInputs(
        uint256 targetEthOut,
        Snapshot[] memory snap,
        uint256 tvlWeth18               // now used
    ) internal pure returns (MultiTokenInput[] memory sells) {
        uint256 n = snap.length;

        // 1) Use provided TVL
        if (tvlWeth18 == 0) revert ZeroTvl();
        if (targetEthOut > tvlWeth18) revert TargetGtTvl();

        // 2) Pro-rata based on snapshot composition, divide by tvlWeth18
        MultiTokenInput[] memory tmp = new MultiTokenInput[](n);
        uint256 count;
        for (uint256 i = 0; i < n; ) {
            uint256 p   = snap[i].tokenPriceWeth18;
            uint256 bal = snap[i].tokenRawBalance;
            if (p != 0 && bal != 0) {
                uint256 targetVal = FullMath.mulDiv(
                    targetEthOut,
                    snap[i].tokenValueWeth18,
                    tvlWeth18
                );

                uint256 raw = FullMath.mulDiv(
                    targetVal,
                    10 ** snap[i].tokenDecimals,
                    p
                );
                if (raw > bal) raw = bal;

                if (raw != 0) {
                    tmp[count++] = MultiTokenInput({
                        tokenAddress: snap[i].tokenAddress,
                        amount: raw
                    });
                }
            }
            unchecked { ++i; }
        }
        if (count == 0) revert EmptyArr();

        sells = new MultiTokenInput[](count);
        for (uint256 i = 0; i < count; ) {
            sells[i] = tmp[i];
            unchecked { ++i; }
        }
    }


    function buildRebalanceRedeemInputs(
        Etf memory etf, 
        Snapshot[] memory snapBefore, 
        uint256 tvlBefore
    ) internal pure returns (MultiTokenInput[] memory sells, uint256 sellCount) {
        // -------------------- Snapshot current vault --------------------
        if (tvlBefore == 0) revert ZeroTvl(); // no TVL → nothing to rebalance

        uint256 n = etf.assets.length;
        uint256[] memory targets = new uint256[](n);
        uint256[] memory currentVals = new uint256[](n);

        // -------------------- Compute target vs. actual --------------------
        for (uint256 i = 0; i < n; ) {
            targets[i] = (uint256(etf.assets[i].weightBips) * tvlBefore) / HUNDRED_PERCENT_BIPS;
            currentVals[i] = snapBefore[i].tokenValueWeth18;
            unchecked { ++i; }
        }

        // -------------------- Identify overweights to sell --------------------
        sells = new MultiTokenInput[](n);

        for (uint256 i = 0; i < n; ) {
            if (currentVals[i] > targets[i]) {
                uint256 excessValue = currentVals[i] - targets[i];
                uint256 rawAmount = FullMath.mulDiv(
                    excessValue,
                    10 ** snapBefore[i].tokenDecimals,
                    snapBefore[i].tokenPriceWeth18
                );
                if (rawAmount > 0) {
                    sells[sellCount++] = MultiTokenInput({
                        tokenAddress: snapBefore[i].tokenAddress,
                        amount: rawAmount
                    });
                }
            }
            unchecked { ++i; }
        }
        if (sellCount == 0) revert RouterInputs.EmptyArr(); // nothing overweight
    }

}