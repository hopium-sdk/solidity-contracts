// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "hopium/uniswap/interface/imMultiSwapRouter.sol";
import "hopium/etf/interface/imEtfOracle.sol";
import "hopium/etf/interface/iEtfToken.sol";
import "hopium/common/types/bips.sol";
import "hopium/etf/interface/iEtfVault.sol";
import "hopium/common/lib/transfer-helpers.sol";
import "hopium/common/interface/imActive.sol";
import "hopium/uniswap/interface/imUniswapOracle.sol";
import "hopium/common/interface-ext/iErc20Metadata.sol";
import "hopium/common/lib/full-math.sol";

error ZeroAmount();
error ZeroReceiver();
error InvalidBips();

abstract contract Storage {
    uint16 public PLATFORM_FEE = 25;
    uint256 internal constant WAD = 1e18;
    uint32 public DEFAULT_SLIPPAGE_BIPS = 300;
}

abstract contract Fee is ImDirectory, Storage, ImEtfFactory {
    function _transferPlatformFee(uint256 amount) internal returns (uint256 netAmount) {
        address vault = fetchFromDirectory("vault");
        uint16 feeBips = PLATFORM_FEE;

        if (vault == address(0) || feeBips == 0) return amount;

        uint256 fee = (amount * uint256(feeBips)) / uint256(HUNDRED_PERCENT_BIPS);
        if (fee != 0) {
            TransferHelpers.sendEth(vault, fee);
            return amount - fee;
        }
        return amount;
    }

    function _refundEthDust(address receiver) internal {
        // Return any dust ETH
        uint256 leftover = address(this).balance;
        if (leftover > 0) TransferHelpers.sendEth(receiver, leftover);
    }
}

abstract contract Hamilton is ImEtfOracle {
    /// @dev Distribute `total` across items proportionally to `numerators`,
    /// using Hamilton/Largest Remainder. If `caps` is provided, each item
    /// is hard-capped (same unit as `total`) and leftover is re-allocated.
    /// - Deterministic tie-breaking by lower index.
    /// - Returns an array `out` s.t. sum(out) == min(total, sum(caps or INF)).
    /// @dev Distribute `total` across items proportionally to `numerators`,
    /// using Hamilton/Largest Remainder. If `caps` is provided (same length),
    /// each item is capped (same units as `total`) and leftover is re-allocated.
    /// Deterministic tie-break by lower index. Sum(out) == min(total, sum(caps or INF)).
    function _hamiltonDistribute(
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

abstract contract MintOutputHelpers is Hamilton {

    /// @notice Build weighted buys for a rebalancing mint (spend only on deficits).
    ///         Guarantees sum(weights) == 10_000.
    function _buildMintOutputs(
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
            uint256[] memory w = _hamiltonDistribute(
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
        uint256[] memory w2 = _hamiltonDistribute(
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

}

abstract contract RedeemInputHelpers is MintOutputHelpers, ImMultiSwapRouter {
    struct _RedeemBuf {
        MultiTokenInput[] arr;
        uint256 count;
        uint256 accum; // estimated ETH18 accumulated
    }

    struct _Cand {
        address[] tok;
        uint8[]   dec;
        uint256[] bal;
        uint256[] p;
        uint256[] val;
        uint256   m;
        uint256   totalVal;
    }

    error EmptyBuf();
    error EmptyCand();
    error CapacityExceeded();
    /// @notice Plan token sells for redeeming ETF to ETH, rebalancing-aware.
    ///         Uses Hamilton allocation with per-token value caps for the second phase.
    /// @return sells Array of token inputs to sell (sized exactly to the number of sells)
    function _buildRedeemInputs(
        Etf memory etf,
        address etfVault,
        uint256 targetEthOut
    ) internal returns (MultiTokenInput[] memory sells) {
        (Snapshot[] memory snap, uint256 tvlWeth18) = getEtfOracle().snapshotVaultUnchecked(etf, etfVault);
        uint256 n = etf.assets.length;

        _RedeemBuf memory buf;
        buf.arr = new MultiTokenInput[](n);

        // -------- Phase 1: sell overweights up to target (skip dust) --------
        for (uint256 i = 0; i < n && buf.accum < targetEthOut; ) {
            uint256 p = snap[i].tokenPriceWeth18; // WETH per 1 token (1e18)
            if (p != 0) {
                uint256 target = (uint256(etf.assets[i].weightBips) * tvlWeth18) / HUNDRED_PERCENT_BIPS;
                if (snap[i].tokenValueWeth18 > target) {
                    uint256 available = snap[i].tokenValueWeth18 - target; // ETH18
                    uint256 need = targetEthOut - buf.accum;
                    uint256 sellVal = available < need ? available : need;  // ETH18

                    if (sellVal != 0) {
                        uint256 raw = FullMath.mulDiv(sellVal, 10 ** snap[i].tokenDecimals, p); // floor
                        if (raw != 0) {
                            uint256 realizedVal = FullMath.mulDiv(raw, p, 10 ** snap[i].tokenDecimals); // ETH18
                            if (realizedVal != 0) {
                                // merge if token already present
                                bool merged;
                                for (uint256 j = 0; j < buf.count; ) {
                                    if (buf.arr[j].tokenAddress == snap[i].tokenAddress) {
                                        buf.arr[j].amount += raw;
                                        merged = true;
                                        break;
                                    }
                                    unchecked { ++j; }
                                }
                                if (!merged) {
                                    if (buf.count >= n) revert CapacityExceeded();
                                    buf.arr[buf.count++] = MultiTokenInput({
                                        tokenAddress: snap[i].tokenAddress,
                                        amount: raw
                                    });
                                }
                                buf.accum += realizedVal;
                            }
                        }
                    }
                }
            }
            unchecked { ++i; }
        }

        // -------- Phase 2: Hamilton on remaining need, with per-token caps and top-ups --------
        if (buf.accum < targetEthOut) {
            uint256 remainingNeed = targetEthOut - buf.accum;

            _Cand memory c;

            // 1) Count candidates (capacity = remaining balance after Phase 1)
            for (uint256 i = 0; i < n; ) {
                uint256 p = snap[i].tokenPriceWeth18;
                uint256 bal = snap[i].tokenRawBalance;
                if (p != 0 && bal != 0) {
                    // compute pre-sold raw for this token
                    uint256 preSoldRaw;
                    for (uint256 j = 0; j < buf.count; ) {
                        if (buf.arr[j].tokenAddress == snap[i].tokenAddress) {
                            preSoldRaw += buf.arr[j].amount;
                        }
                        unchecked { ++j; }
                    }
                    if (preSoldRaw < bal) {
                        unchecked { ++c.m; }
                    }
                }
                unchecked { ++i; }
            }
            if (c.m == 0) revert EmptyCand();

            // 2) allocate arrays
            c.tok = new address[](c.m);
            c.dec = new uint8[](c.m);
            c.bal = new uint256[](c.m);       // remaining raw capacity
            c.p   = new uint256[](c.m);
            c.val = new uint256[](c.m);       // cap value (ETH18), also numerator

            // 3) fill candidates
            {
                uint256 k;
                for (uint256 i = 0; i < n; ) {
                    uint256 p = snap[i].tokenPriceWeth18;
                    uint256 bal = snap[i].tokenRawBalance;
                    if (p != 0 && bal != 0) {
                        uint256 preSoldRaw;
                        for (uint256 j = 0; j < buf.count; ) {
                            if (buf.arr[j].tokenAddress == snap[i].tokenAddress) {
                                preSoldRaw += buf.arr[j].amount;
                            }
                            unchecked { ++j; }
                        }
                        if (preSoldRaw < bal) {
                            uint256 remainingRaw = bal - preSoldRaw;
                            uint256 capVal = FullMath.mulDiv(remainingRaw, p, 10 ** snap[i].tokenDecimals); // ETH18
                            if (capVal != 0) {
                                c.tok[k] = snap[i].tokenAddress;
                                c.dec[k] = snap[i].tokenDecimals;
                                c.bal[k] = remainingRaw;
                                c.p[k]   = p;
                                c.val[k] = capVal;
                                c.totalVal += capVal;
                                unchecked { ++k; }
                            }
                        }
                    }
                    unchecked { ++i; }
                }
                if (c.totalVal == 0) revert EmptyCand();
            }

            // 4) Hamilton allocate remainingNeed with caps
            uint256[] memory allocVal = _hamiltonDistribute(c.val, remainingNeed, c.val);

            // 5) convert value->raw and MERGE into buf (no duplicates, no raw=1)
            for (uint256 i = 0; i < c.m; ) {
                uint256 takeVal = allocVal[i]; // ETH18
                if (takeVal != 0) {
                    uint256 raw = FullMath.mulDiv(takeVal, 10 ** c.dec[i], c.p[i]); // floor
                    if (raw != 0) {
                        if (raw > c.bal[i]) raw = c.bal[i];

                        // merge if already present, else push
                        bool merged;
                        for (uint256 j = 0; j < buf.count; ) {
                            if (buf.arr[j].tokenAddress == c.tok[i]) {
                                buf.arr[j].amount += raw;
                                merged = true;
                                break;
                            }
                            unchecked { ++j; }
                        }
                        if (!merged) {
                            if (buf.count >= n) revert CapacityExceeded();
                            buf.arr[buf.count++] = MultiTokenInput({
                                tokenAddress: c.tok[i],
                                amount: raw
                            });
                        }

                        uint256 realizedVal = FullMath.mulDiv(raw, c.p[i], 10 ** c.dec[i]); // ETH18
                        buf.accum += realizedVal;
                    }
                }
                unchecked { ++i; }
            }
        }

        if (buf.count == 0) revert EmptyBuf();

        // -------- finalize / execute vault redemptions --------
        sells = new MultiTokenInput[](buf.count);
        for (uint256 i = 0; i < buf.count; ) {
            sells[i] = buf.arr[i];
            unchecked { ++i; }
        }

        address routerAddress = address(getMultiSwapRouter());
        for (uint256 i = 0; i < sells.length; ) {
            IEtfVault(etfVault).redeem(
                sells[i].tokenAddress,
                sells[i].amount,
                routerAddress
            );
            unchecked { ++i; }
        }
    }
}

abstract contract MintRedeemHelpers is Fee, RedeemInputHelpers {

    error ZeroEtfPrice();
    error NoMintedAmount();
    error DeltaError();
    function _mintEtfTokens(uint256 etfId, Etf memory etf, address etfToken, address etfVault, address receiver) internal returns (uint256 minted, uint256 delta) {
        // Net ETH after platform fee
        uint256 ethBudget = _transferPlatformFee(msg.value);

        // Snapshot BEFORE
        (Snapshot[] memory snapBefore, uint256 tvlBefore) = getEtfOracle().snapshotVaultUnchecked(etf, etfVault);
        uint256 supply0  = IERC20(etfToken).totalSupply();

        // Build + execute swaps
        MultiTokenOutput[] memory buys = _buildMintOutputs(etf, ethBudget, snapBefore, tvlBefore);
        getMultiSwapRouter().swapEthToMultipleTokens{value: ethBudget}(
            buys,
            etfVault,
            DEFAULT_SLIPPAGE_BIPS
        );

        // Snapshot AFTER
        (, uint256 tvlAfter) = getEtfOracle().snapshotVaultUnchecked(etf, etfVault);
        if (tvlAfter <= tvlBefore) revert DeltaError();
        delta = tvlAfter - tvlBefore;

        // Mint amount
        if (supply0 == 0) {
            // Genesis: use oracle index NAV (WETH per ETF token, 1e18)
            uint256 priceWeth18 = getEtfOracle().getEtfWethPrice(etfId);
            if (priceWeth18 == 0) revert ZeroEtfPrice();
            // tokens = value / price
            minted = FullMath.mulDiv(delta, WAD, priceWeth18);
        } else {
            // Proportional mint at current NAV
            // minted = delta * supply0 / tvlBefore  (floor)
            minted = FullMath.mulDiv(delta, supply0, tvlBefore);
        }
        if (minted == 0) revert NoMintedAmount();

        // Mint to receiver
        IEtfToken(etfToken).mint(receiver, minted);
    }

    error SupplyZero();
    function _redeemEtfTokens(uint256 etfId, Etf memory etf, address etfTokenAddress, address etfVaultAddress, uint256 etfTokenAmount, address payable receiver) internal returns (uint256) {
        uint256 supply = IERC20(etfTokenAddress).totalSupply();
        if (supply == 0) revert SupplyZero();

        // NAV target payment (+ small buffer for market frictions)
        uint256 priceWeth18 = getEtfOracle().getEtfWethPrice(etfId);
        if (priceWeth18 == 0) revert ZeroEtfPrice();
        uint256 targetEth = FullMath.mulDiv(etfTokenAmount, priceWeth18, WAD);

        // Build sells (rebalance-aware) and pull tokens from vault
        MultiTokenInput[] memory sells = _buildRedeemInputs(etf, etfVaultAddress, targetEth);

        //Snapshot before
        uint256 ethBefore = address(this).balance;

        // Execute: tokens -> ETH straight to receiver (we already pre-transferred)
        getMultiSwapRouter().swapMultipleTokensToEth(sells, payable(address(this)), DEFAULT_SLIPPAGE_BIPS, true);

        //Snapshot after
        uint256 ethAfter = address(this).balance;
        uint256 ethRealized = ethAfter > ethBefore ? ethAfter - ethBefore : 0;
        if (ethRealized == 0) revert ZeroAmount();

        // Net ETH after platform fee
        uint256 ethFinal = _transferPlatformFee(ethRealized);

        // Send to receiver
        TransferHelpers.sendEth(receiver, ethFinal);

        // Burn user tokens
        IEtfToken(etfTokenAddress).burn(msg.sender, etfTokenAmount);

        return ethFinal;
    }
}

abstract contract RebalanceHelpers is MintRedeemHelpers {

    function _buildRebalanceRedeemInputs(Etf memory etf, address etfVaultAddress) internal view returns (MultiTokenInput[] memory sells, uint256 sellCount) {
        // -------------------- Snapshot current vault --------------------
        (Snapshot[] memory snapBefore, uint256 tvlBefore) = getEtfOracle().snapshotVaultUnchecked(etf, etfVaultAddress);
        if (tvlBefore == 0) revert ZeroAmount(); // no TVL → nothing to rebalance

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
        if (sellCount == 0) revert EmptyBuf(); // nothing overweight
    }

    function _rebalance(Etf memory etf, address etfVaultAddress) internal {
        // -------------------- Build Sell Inputs --------------------

        (MultiTokenInput[] memory sells, uint256 sellCount) = _buildRebalanceRedeemInputs(etf, etfVaultAddress);

        // -------------------- Execute sells (vault → router → ETH) --------------------
        address routerAddress = address(getMultiSwapRouter());
        uint256 ethBefore = address(this).balance;

        for (uint256 i = 0; i < sellCount; ) {
            IEtfVault(etfVaultAddress).redeem(
                sells[i].tokenAddress,
                sells[i].amount,
                routerAddress
            );
            unchecked { ++i; }
        }

        getMultiSwapRouter().swapMultipleTokensToEth(
            sells,
            payable(address(this)),
            DEFAULT_SLIPPAGE_BIPS,
            true
        );

        uint256 ethAfter = address(this).balance;
        uint256 ethRealized = ethAfter > ethBefore ? ethAfter - ethBefore : 0;
        if (ethRealized == 0) revert ZeroAmount();

        // -------------------- Recompute snapshot and buy underweights --------------------
        (Snapshot[] memory snapMid, uint256 tvlMid) = getEtfOracle().snapshotVaultUnchecked(etf, etfVaultAddress);
        MultiTokenOutput[] memory buys = _buildMintOutputs(etf, ethRealized, snapMid, tvlMid);

        // -------------------- Execute buys (ETH → vault tokens) --------------------
        getMultiSwapRouter().swapEthToMultipleTokens{ value: ethRealized }(
            buys,
            etfVaultAddress,
            DEFAULT_SLIPPAGE_BIPS
        );
    }
}

contract EtfRouter is ReentrancyGuard, ImActive, RebalanceHelpers  {
    constructor(address _directory) ImDirectory(_directory) {}

    function mintEtfTokens(uint256 etfId, address receiver) external payable nonReentrant onlyActive {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroReceiver();

        // Resolve config
        (Etf memory etf, address etfToken, address etfVault) = getEtfFactory().getEtfByIdAndAddresses(etfId);

        _mintEtfTokens(etfId, etf, etfToken, etfVault, receiver);

        _refundEthDust(msg.sender);

        getEtfFactory().emitVaultBalanceEvent(etfId);
    }

    // -------- Redeem to ETH --------
    function redeemEtfTokens(uint256 etfId, uint256 etfTokenAmount, address payable receiver) external nonReentrant onlyActive {
        if (etfTokenAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroReceiver();

        (Etf memory etf, address etfTokenAddress, address etfVaultAddress) = getEtfFactory().getEtfByIdAndAddresses(etfId);

        _redeemEtfTokens(etfId, etf, etfTokenAddress, etfVaultAddress, etfTokenAmount, receiver);

        getEtfFactory().emitVaultBalanceEvent(etfId);
    }

    function rebalance(uint256 etfId) external nonReentrant onlyActive {
        (Etf memory etf, address etfVaultAddress) = getEtfFactory().getEtfByIdAndVault(etfId);
        _rebalance(etf, etfVaultAddress);
       _refundEthDust(msg.sender);

        getEtfFactory().emitVaultBalanceEvent(etfId);
    }

    function changePlatformFee(uint16 newFee) public onlyOwner onlyActive {
        if (newFee > HUNDRED_PERCENT_BIPS) revert InvalidBips();
        PLATFORM_FEE = newFee;
    }

     function changeDefaultSlippage(uint32 newSlippageBips) external onlyOwner {
        if (newSlippageBips > HUNDRED_PERCENT_BIPS) revert InvalidBips();
        DEFAULT_SLIPPAGE_BIPS = newSlippageBips;
    }

    function recoverAsset(address tokenAddress, address toAddress) public onlyOwner {
        TransferHelpers.recoverAsset(tokenAddress, toAddress);
    }

    receive() external payable {}
}