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

    event EtfTokensMinted(uint256 etfId, address caller, address receiver, uint256 etfTokenAmount, uint256 ethAmount);
    event EtfTokensRedeemed(uint256 etfId, address caller, address receiver, uint256 etfTokenAmount, uint256 ethAmount);
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

abstract contract MintOutputHelpers is ImEtfOracle {
    /// @dev Normalize a set of numerators so the resulting uint16 bips sum exactly to denomBips.
    /// Uses the Hamilton / Largest Remainder method with deterministic tie-breaking by index.
    function _normalizeToBips(
        uint256[] memory numerators,
        uint256 denomBips
    ) internal pure returns (uint16[] memory out) {
        uint256 n = numerators.length;
        out = new uint16[](n);

        if (n == 0 || denomBips == 0) return out;

        uint256 sumNum;
        for (uint256 i = 0; i < n; ) {
            sumNum += numerators[i];
            unchecked { ++i; }
        }
        if (sumNum == 0) return out; // all zeros → all zero weights

        // First pass: floor allocation and remainder capture
        // We keep remainders in 256-bit for precision; we don't need struct packing here.
        uint256[] memory rema = new uint256[](n);
        uint256 acc;
        for (uint256 i = 0; i < n; ) {
            // w_i = floor(n_i * denom / sumNum)
            uint256 prod = numerators[i] * denomBips;
            uint256 w = prod / sumNum;
            if (w > type(uint16).max) w = type(uint16).max; // ultra defensive; denomBips fits anyway
            out[i] = uint16(w);
            acc += w;

            // remainder r_i = prod % sumNum (bigger r_i gets priority for +1)
            rema[i] = prod - (w * sumNum);
            unchecked { ++i; }
        }

        // If we’re short, hand out the remaining units to largest remainders.
        // If we overshot (shouldn't happen with floor), trim from smallest remainders (deterministic).
        if (acc < denomBips) {
            uint256 need = denomBips - acc;
            // Distribute +1 to the 'need' largest remainders (ties resolved by lower index first)
            for (; need > 0; ) {
                // single pass argmax (n is typically tiny)
                uint256 bestIdx = 0;
                uint256 bestRem = 0;
                for (uint256 i = 0; i < n; ) {
                    // Skip if already saturated at uint16::max (not really possible with denom 10k)
                    if (rema[i] > bestRem && out[i] < type(uint16).max) {
                        bestRem = rema[i];
                        bestIdx = i;
                    }
                    unchecked { ++i; }
                }
                // If all rema are zero (can happen), just give to the lowest index not saturated
                if (bestRem == 0) {
                    bool given = false;
                    for (uint256 i = 0; i < n; ) {
                        if (out[i] < type(uint16).max) {
                            out[i] += 1;
                            given = true;
                            break;
                        }
                        unchecked { ++i; }
                    }
                    if (!given) break; // nothing we can do
                } else {
                    out[bestIdx] += 1;
                    // set to zero to avoid picking again too early (fairness)
                    rema[bestIdx] = 0;
                }
                unchecked { --need; }
            }
        } else if (acc > denomBips) {
            uint256 over = acc - denomBips;
            // Remove -1 from the 'over' smallest remainders first (mirror logic)
            for (; over > 0; ) {
                uint256 bestIdx = 0;
                uint256 bestRem = type(uint256).max;
                for (uint256 i = 0; i < n; ) {
                    if (out[i] > 0 && rema[i] < bestRem) {
                        bestRem = rema[i];
                        bestIdx = i;
                    }
                    unchecked { ++i; }
                }
                if (out[bestIdx] == 0) break; // safety
                out[bestIdx] -= 1;
                // push its remainder high so it won't be picked again immediately
                rema[bestIdx] = type(uint256).max;
                unchecked { --over; }
            }
        }
    }

    /// @notice Build weighted buys for a rebalancing mint (spend only on deficits).
    ///         Guarantees sum(weights) == 10_000.
    /// @return buys MultiTokenOutput[] sized to number of underweight tokens (or all if no deficits)
    function _buildMintOutputs(
        Etf memory etf,
        uint256 ethBudget,
        Snapshot[] memory snap,
        uint256 tvlWeth18
    ) internal pure returns (MultiTokenOutput[] memory buys) {
        uint256 postMintTVLWeth18 = tvlWeth18 + ethBudget;

        uint256 n = etf.assets.length;
        // First collect tokens that are underweight
        address[] memory uwTokens = new address[](n);
        uint256[] memory uwDeficit = new uint256[](n);
        uint256 uwCount;
        uint256 totalDeficitWeth18;

        for (uint256 i = 0; i < n; ) {
            uint256 target = (uint256(etf.assets[i].weightBips) * postMintTVLWeth18) / HUNDRED_PERCENT_BIPS;
            uint256 cur    = snap[i].tokenValueWeth18;
            if (target > cur) {
                uint256 deficit = target - cur; // > 0
                uwTokens[uwCount]  = snap[i].tokenAddress;
                uwDeficit[uwCount] = deficit;
                totalDeficitWeth18 += deficit;
                unchecked { ++uwCount; }
            }
            unchecked { ++i; }
        }

        if (uwCount == 0) {
            // Nothing underweight — fall back to normalized target weights (don’t assume they sum to 10_000)
            uint16[] memory norm = new uint16[](n);
            {
                uint256[] memory numerators = new uint256[](n);
                for (uint256 i = 0; i < n; ) {
                    numerators[i] = etf.assets[i].weightBips;
                    unchecked { ++i; }
                }
                norm = _normalizeToBips(numerators, HUNDRED_PERCENT_BIPS);
            }

            buys = new MultiTokenOutput[](n);
            uint256 sum;
            for (uint256 i = 0; i < n; ) {
                buys[i] = MultiTokenOutput({
                    tokenAddress: snap[i].tokenAddress,
                    weightBips:   norm[i]
                });
                sum += buys[i].weightBips;
                unchecked { ++i; }
            }
            if (sum != HUNDRED_PERCENT_BIPS) revert InvalidBips(); // should be exact by construction
            return buys;
        }

        // Allocate ETH proportionally to deficits and normalize to exactly 10_000
        {
            // shrink buffers to uwCount for normalization pass
            address[] memory toks = new address[](uwCount);
            uint256[] memory numerators = new uint256[](uwCount);

            for (uint256 i = 0; i < uwCount; ) {
                toks[i]       = uwTokens[i];
                numerators[i] = uwDeficit[i]; // proportional to deficit value in WETH18
                unchecked { ++i; }
            }

            uint16[] memory wNorm = _normalizeToBips(numerators, HUNDRED_PERCENT_BIPS);

            buys = new MultiTokenOutput[](uwCount);
            uint256 sumB;
            for (uint256 i = 0; i < uwCount; ) {
                buys[i] = MultiTokenOutput({ tokenAddress: toks[i], weightBips: wNorm[i] });
                sumB += wNorm[i];
                unchecked { ++i; }
            }
            if (sumB != HUNDRED_PERCENT_BIPS) revert InvalidBips(); // exact by construction
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
    function _buildRedeemInputs(
        Etf memory etf,
        address etfVault,
        uint256 targetEthOut
    ) internal returns (MultiTokenInput[] memory sells) {
        (Snapshot[] memory snap, uint256 tvlWeth18) = getEtfOracle().snapshotVaultUnchecked(etf, etfVault);
        uint256 n = etf.assets.length;

        _RedeemBuf memory buf;
        buf.arr = new MultiTokenInput[](n); // upper bound

        // -------- Phase 1: plan sells from overweights (no external calls) --------
        {
            for (uint256 i = 0; i < n && buf.accum < targetEthOut; ) {
                uint256 target = (uint256(etf.assets[i].weightBips) * tvlWeth18) / HUNDRED_PERCENT_BIPS;
                uint256 p = snap[i].tokenPriceWeth18;

                if (p != 0 && snap[i].tokenValueWeth18 > target) {
                    uint256 available = snap[i].tokenValueWeth18 - target;
                    uint256 need = targetEthOut - buf.accum;
                    uint256 sellVal = available < need ? available : need;

                    if (sellVal != 0) {
                        uint256 raw = FullMath.mulDiv(sellVal, 10 ** snap[i].tokenDecimals, p);
                        if (raw == 0 && snap[i].tokenRawBalance != 0) raw = 1;

                        uint256 realizedVal = FullMath.mulDiv(raw, p, 10 ** snap[i].tokenDecimals);
                        if (realizedVal != 0) {
                            buf.arr[buf.count++] = MultiTokenInput({ tokenAddress: snap[i].tokenAddress, amount: raw });
                            buf.accum += realizedVal;
                        }
                    }
                }
                unchecked { ++i; }
            }
        }

        // -------- Phase 2: proportional plan from remaining (still no external calls) --------
        if (buf.accum < targetEthOut) {
            uint256 remainingNeed = targetEthOut - buf.accum;

            _Cand memory c;
            c.tok = new address[](n);
            c.dec = new uint8[](n);
            c.bal = new uint256[](n);
            c.p   = new uint256[](n);
            c.val = new uint256[](n);

            // gather candidates
            {
                for (uint256 i = 0; i < n; ) {
                    bool already;
                    for (uint256 j = 0; j < buf.count; ) {
                        if (buf.arr[j].tokenAddress == snap[i].tokenAddress) { already = true; break; }
                        unchecked { ++j; }
                    }

                    uint256 p = snap[i].tokenPriceWeth18;
                    if (!already && p != 0 && snap[i].tokenRawBalance != 0) {
                        uint256 availRaw = snap[i].tokenRawBalance;
                        uint256 availVal = FullMath.mulDiv(availRaw, p, 10 ** snap[i].tokenDecimals);
                        if (availVal != 0) {
                            c.tok[c.m] = snap[i].tokenAddress;
                            c.dec[c.m] = snap[i].tokenDecimals;
                            c.bal[c.m] = availRaw;
                            c.p[c.m]   = p;
                            c.val[c.m] = availVal;
                            c.totalVal += availVal;
                            unchecked { ++c.m; }
                        }
                    }
                    unchecked { ++i; }
                }
                if (c.m == 0) revert EmptyCand();
            }

            // proportional first pass
            uint256 mintedThisPass;
            {
                for (uint256 i = 0; i < c.m; ) {
                    uint256 v = c.val[i];
                    if (v != 0) {
                        uint256 takeVal = FullMath.mulDiv(remainingNeed, v, c.totalVal);
                        if (takeVal > v) takeVal = v;

                        if (takeVal != 0) {
                            uint256 raw = FullMath.mulDiv(takeVal, 10 ** c.dec[i], c.p[i]);
                            if (raw == 0 && c.bal[i] != 0) raw = 1;
                            if (raw > c.bal[i]) raw = c.bal[i];

                            uint256 realizedVal = FullMath.mulDiv(raw, c.p[i], 10 ** c.dec[i]);
                            if (realizedVal != 0) {
                                buf.arr[buf.count++] = MultiTokenInput({ tokenAddress: c.tok[i], amount: raw });

                                c.bal[i] -= raw;
                                uint256 spent = realizedVal > v ? v : realizedVal;
                                c.val[i] = v - spent;
                                mintedThisPass += realizedVal;
                            }
                        }
                    }
                    unchecked { ++i; }
                }
                buf.accum += mintedThisPass;
            }

            // mop-up from largest headroom
            if (buf.accum < targetEthOut) {
                uint256 shortfall = targetEthOut - buf.accum;

                uint256 bestIdx = type(uint256).max;
                uint256 bestHeadroom;
                for (uint256 i = 0; i < c.m; ) {
                    if (c.bal[i] != 0) {
                        uint256 headroomVal = FullMath.mulDiv(c.bal[i], c.p[i], 10 ** c.dec[i]);
                        if (headroomVal > bestHeadroom) {
                            bestHeadroom = headroomVal;
                            bestIdx = i;
                        }
                    }
                    unchecked { ++i; }
                }

                if (bestIdx != type(uint256).max && bestHeadroom != 0) {
                    uint256 takeVal = shortfall < bestHeadroom ? shortfall : bestHeadroom;
                    uint256 raw = FullMath.mulDiv(takeVal, 10 ** c.dec[bestIdx], c.p[bestIdx]);
                    if (raw == 0) raw = 1;
                    if (raw > c.bal[bestIdx]) raw = c.bal[bestIdx];

                    uint256 realizedVal = FullMath.mulDiv(raw, c.p[bestIdx], 10 ** c.dec[bestIdx]);
                    if (realizedVal != 0) {
                        buf.arr[buf.count++] = MultiTokenInput({ tokenAddress: c.tok[bestIdx], amount: raw });
                        buf.accum += realizedVal;
                    }
                }
            }
        }

        if (buf.count == 0) revert EmptyBuf();

        address routerAddress = address(getMultiSwapRouter());
        // -------- Phase 3: perform redemptions at the end --------
        sells = new MultiTokenInput[](buf.count);
        for (uint256 i = 0; i < buf.count; ) {
            MultiTokenInput memory it = buf.arr[i];
            sells[i] = it;
            IEtfVault(etfVault).redeem(it.tokenAddress, it.amount, routerAddress);
            unchecked { ++i; }
        }
    }
}

abstract contract MintRedeemHelpers is Fee, RedeemInputHelpers {

    error ZeroEtfPrice();
    error NoMintedAmount();
    error DeltaError();
    function _mintEtfTokens(uint256 etfId, address receiver) internal returns (uint256 minted, uint256 delta) {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroReceiver();

        // Resolve config
        (Etf memory etf, address etfToken, address etfVault) = getEtfFactory().getEtfByIdAndAddresses(etfId);

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
    function _redeemEtfTokens(uint256 etfId, uint256 etfTokenAmount, address payable receiver) internal returns (uint256) {
        if (etfTokenAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroReceiver();

        (Etf memory etf, address etfTokenAddress, address etfVaultAddress) = getEtfFactory().getEtfByIdAndAddresses(etfId);

        uint256 supply = IERC20(etfTokenAddress).totalSupply();
        if (supply == 0) revert SupplyZero();

        // NAV target payment (+ small buffer for market frictions)
        uint256 priceWeth18 = getEtfOracle().getEtfWethPrice(etfId);
        if (priceWeth18 == 0) revert ZeroEtfPrice();
        uint256 targetEth = FullMath.mulDiv(etfTokenAmount, priceWeth18, WAD);

        // Burn user shares first
        IEtfToken(etfTokenAddress).burn(msg.sender, etfTokenAmount);

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

    function _rebalance(uint256 etfId) internal {
        (Etf memory etf, address etfVaultAddress) = getEtfFactory().getEtfByIdAndVault(etfId);

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

contract EtfRouter is ReentrancyGuard, ImActive, RebalanceHelpers {
    constructor(address _directory) ImDirectory(_directory) {}

    function mintEtfTokens(uint256 etfId, address receiver) external payable nonReentrant onlyActive {
        (uint256 tokensMinted, uint256 ethAmount) = _mintEtfTokens(etfId, receiver);

        _refundEthDust(msg.sender);

        emit EtfTokensMinted(etfId, msg.sender, receiver, tokensMinted, ethAmount);
    }

    // -------- Redeem to ETH --------
    function redeemEtfTokens(uint256 etfId, uint256 etfTokenAmount, address payable receiver) external nonReentrant onlyActive {
        uint256 ethAmount = _redeemEtfTokens(etfId, etfTokenAmount, receiver);

        emit EtfTokensRedeemed(etfId, msg.sender, receiver, etfTokenAmount, ethAmount);
    }

    function rebalance(uint256 etfId) external nonReentrant onlyActive {
        _rebalance(etfId);
       _refundEthDust(msg.sender);
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