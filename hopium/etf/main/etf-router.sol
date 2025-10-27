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
import "hopium/etf/lib/router-inputs.sol";
import "hopium/etf/interface/imEtfAffiliate.sol";

error ZeroAmount();
error ZeroReceiver();
error InvalidBips();

abstract contract Storage {
    uint16 public PLATFORM_FEE_BIPS = 50;
    uint16 public AFFILIATE_USER_DISCOUNT_PERC = 25;
    uint256 internal constant WAD = 1e18;
    uint32 public DEFAULT_SLIPPAGE_BIPS = 300;
}

abstract contract Fee is ImDirectory, Storage, ImEtfFactory, ImEtfAffiliate {
    /// @notice Transfers platform fee, optionally splitting with an affiliate.
    /// @dev
    ///  - If `affiliateCode` is empty or has no owner → 100% of fee to vault.
    ///  - If code has owner:
    ///       total fee = 75% of PLATFORM_FEE,
    ///       split 50% to vault and 50% to affiliate owner.
    /// @return netAmount ETH remaining after fee deduction.
    function _transferPlatformFee(
        uint256 etfId,
        uint256 amount,
        string calldata affiliateCode
    ) internal returns (uint256 netAmount) {
        address vault = fetchFromDirectory("vault");
        uint16 feeBips = PLATFORM_FEE_BIPS;
        if (vault == address(0) || feeBips == 0) return amount;

        IEtfAffiliate affiliate = getEtfAffiliate();

        address codeOwner;
        if (bytes(affiliateCode).length != 0) {
            codeOwner = affiliate.getAffiliateOwner(affiliateCode);
        }

        // Compute the base platform fee
        uint256 fee = (amount * uint256(feeBips)) / uint256(HUNDRED_PERCENT_BIPS);
        if (fee == 0) return amount;

        // --- Case 1: no affiliate owner ---
        if (codeOwner == address(0)) {
            TransferHelpers.sendEth(vault, fee);
            getEtfFactory().emitPlatformFeeTransferredEvent(etfId, fee);
            return amount - fee;
        }

        // --- Case 2: valid affiliate owner ---
        // charge only 75% of the normal fee
        uint256 discountedFee = (fee * (100 - AFFILIATE_USER_DISCOUNT_PERC)) / 100;
        // split 50/50 between vault and affiliate
        uint256 half = discountedFee / 2;

        TransferHelpers.sendEth(vault, half);
        TransferHelpers.sendEth(payable(codeOwner), half);
        affiliate.emitFeeTransferredEvent(affiliateCode, half);
        getEtfFactory().emitPlatformFeeTransferredEvent(etfId, half);

        return amount - discountedFee;
    }

    function _refundEthDust(address receiver) internal {
        // Return any dust ETH
        uint256 leftover = address(this).balance;
        if (leftover > 0) TransferHelpers.sendEth(receiver, leftover);
    }
}

abstract contract MultiSwapHelpers is Fee, ImMultiSwapRouter {
    function _transferTokensToMultiswapRouter(MultiTokenInput[] memory sells, address etfVaultAddress) internal {
        address routerAddress = address(getMultiSwapRouter());
        for (uint256 i = 0; i < sells.length; ) {
            IEtfVault(etfVaultAddress).redeem(
                sells[i].tokenAddress,
                sells[i].amount,
                routerAddress
            );
            unchecked { ++i; }
        }
    }

    error ZeroDelta();
    function _swapMultipleTokensToEth(MultiTokenInput[] memory sells, address etfVaultAddress) internal returns (uint256 ethRealised) {
        // Pre-transfer vault tokens to router
        _transferTokensToMultiswapRouter(sells, etfVaultAddress);

        // Balance snapshot
        uint256 ethBefore = address(this).balance;

        // Execute swaps -> ETH to this contract
        getMultiSwapRouter().swapMultipleTokensToEth(
            sells,
            payable(address(this)),
            DEFAULT_SLIPPAGE_BIPS,
            true
        );

        // Compute realized ETH
        uint256 ethAfter = address(this).balance;
        if (ethAfter <= ethBefore) revert ZeroDelta();
        
        ethRealised = ethAfter - ethBefore;
    }
}

abstract contract MintHelpers is ImEtfOracle, MultiSwapHelpers {

    function _calMintAmount(uint256 etfId, uint256 totalSupplyBefore, uint256 tvlBefore, uint256 ethRealised) internal view returns (uint256 mintAmount) {
        if (totalSupplyBefore == 0) {
            // Genesis: use oracle index NAV (WETH per ETF token, 1e18)
            uint256 priceWeth18 = getEtfOracle().getEtfWethPrice(etfId);
            if (priceWeth18 == 0) revert ZeroEtfPrice();
            // tokens = value / price
            mintAmount = FullMath.mulDiv(ethRealised, WAD, priceWeth18);
        } else {
            // Proportional mint at current NAV: minted = delta * supply0 / tvlBefore
            mintAmount = FullMath.mulDiv(ethRealised, totalSupplyBefore, tvlBefore);
        }
        if (mintAmount == 0) revert NoMintedAmount();
    }

    function _executeMintBuys(Etf memory etf, address etfVaultAddress, uint256 ethBudget) internal returns (uint256 tvlBefore_, uint256 ethRealised) {
        // Snapshot Before
        (Snapshot[] memory snapBefore, uint256 tvlBefore) = getEtfOracle().snapshotVaultUnchecked(etf, etfVaultAddress);

        //Build + execute swaps
        MultiTokenOutput[] memory buys = RouterInputs.buildMintOutputs(etf, ethBudget, snapBefore, tvlBefore);

        getMultiSwapRouter().swapEthToMultipleTokens{value: ethBudget}(buys, etfVaultAddress, DEFAULT_SLIPPAGE_BIPS);
        
        //Snapshot After
        (, uint256 tvlAfter) = getEtfOracle().snapshotVaultUnchecked(etf, etfVaultAddress);
       
        if (tvlAfter <= tvlBefore) revert DeltaError();
        ethRealised = tvlAfter - tvlBefore;
        tvlBefore_ = tvlBefore;
    }
    
    error ZeroEtfPrice();
    error NoMintedAmount();
    error DeltaError();
    function _mintEtfTokens(
        uint256 etfId,
        Etf memory etf,
        address etfTokenAddress,
        address etfVaultAddress,
        address receiver,
        string calldata affiliateCode
    ) internal returns (uint256 mintAmount, uint256 ethRealised_) {
        // Net ETH after platform fee
        uint256 ethBudget = _transferPlatformFee(etfId, msg.value, affiliateCode);
        
        // Snapshot totalSupply before
        uint256 totalSupplyBefore = IERC20(etfTokenAddress).totalSupply();

        // Buy tokens
        (uint256 tvlBefore, uint256 ethRealised) = _executeMintBuys(etf, etfVaultAddress, ethBudget);

        // Mint amount
        mintAmount = _calMintAmount(etfId, totalSupplyBefore, tvlBefore, ethRealised);

        // Mint to receiver
        IEtfToken(etfTokenAddress).mint(receiver, mintAmount);
        ethRealised_ = ethRealised;
    }

}

abstract contract RedeemHelpers is MintHelpers {

    function _executeRedeemSells(uint256 etfId, Etf memory etf, uint256 etfTokenAmount, address etfVaultAddress) internal returns (uint256 ethRealised) {
        uint256 priceWeth18 = getEtfOracle().getEtfWethPrice(etfId);
        if (priceWeth18 == 0) revert ZeroEtfPrice();

        uint256 targetEth = FullMath.mulDiv(etfTokenAmount, priceWeth18, WAD);

        (Snapshot[] memory snap, uint256 tvlWeth18) = getEtfOracle().snapshotVaultUnchecked(etf, etfVaultAddress);

        // Build sells
        MultiTokenInput[] memory sells = RouterInputs.buildRedeemInputs(targetEth, snap, tvlWeth18);

        //Execute sells
        ethRealised = _swapMultipleTokensToEth(sells, etfVaultAddress);
    } 

    error SupplyZero();
    function _redeemEtfTokens(
        uint256 etfId,
        Etf memory etf,
        address etfTokenAddress,
        address etfVaultAddress,
        uint256 etfTokenAmount,
        address payable receiver,
        string calldata affiliateCode
    ) internal returns (uint256) {
        // Sell tokens
        uint256 ethRealised = _executeRedeemSells(etfId, etf, etfTokenAmount, etfVaultAddress);

        // Platform fee & payout
        uint256 ethFinal = _transferPlatformFee(etfId, ethRealised, affiliateCode);

        //Send final Eth to Receiver
        TransferHelpers.sendEth(receiver, ethFinal);

        // Burn ETF tokens
        IEtfToken(etfTokenAddress).burn(msg.sender, etfTokenAmount);

        return ethFinal;
    }
}

abstract contract RebalanceHelpers is RedeemHelpers {

    function _rebalance(Etf memory etf, address etfVaultAddress) internal {
        // Build sell inputs
        (Snapshot[] memory snapBefore, uint256 tvlBefore) = getEtfOracle().snapshotVaultUnchecked(etf, etfVaultAddress);
        (MultiTokenInput[] memory sells,) = RouterInputs.buildRebalanceRedeemInputs(etf, snapBefore, tvlBefore);

        // Execute sells
        uint256 ethRealised = _swapMultipleTokensToEth(sells, etfVaultAddress);

        // Recompute snapshot and buy underweights
        (Snapshot[] memory snapMid, uint256 tvlMid) = getEtfOracle().snapshotVaultUnchecked(etf, etfVaultAddress);
        MultiTokenOutput[] memory buys = RouterInputs.buildMintOutputs(etf, ethRealised, snapMid, tvlMid);

        // Execute buys (ETH → vault tokens)
        getMultiSwapRouter().swapEthToMultipleTokens{ value: ethRealised }(
            buys,
            etfVaultAddress,
            DEFAULT_SLIPPAGE_BIPS
        );
    }
}

contract EtfRouter is ReentrancyGuard, ImActive, RebalanceHelpers  {
    constructor(address _directory) ImDirectory(_directory) {}

    function mintEtfTokens(uint256 etfId, address receiver, string calldata affiliateCode) external payable nonReentrant onlyActive {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroReceiver();

        // Resolve config
        (Etf memory etf, address etfToken, address etfVault) = getEtfFactory().getEtfByIdAndAddresses(etfId);

        _mintEtfTokens(etfId, etf, etfToken, etfVault, receiver, affiliateCode);

        _refundEthDust(msg.sender);

        getEtfFactory().emitVaultBalanceEvent(etfId);
    }

    // -------- Redeem to ETH --------
    function redeemEtfTokens(uint256 etfId, uint256 etfTokenAmount, address payable receiver, string calldata affiliateCode) external nonReentrant onlyActive {
        if (etfTokenAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroReceiver();

        (Etf memory etf, address etfTokenAddress, address etfVaultAddress) = getEtfFactory().getEtfByIdAndAddresses(etfId);

        _redeemEtfTokens(etfId, etf, etfTokenAddress, etfVaultAddress, etfTokenAmount, receiver, affiliateCode);

        getEtfFactory().emitVaultBalanceEvent(etfId);
    }

    function rebalance(uint256 etfId) external nonReentrant onlyActive {
        (Etf memory etf, address etfVaultAddress) = getEtfFactory().getEtfByIdAndVault(etfId);
        _rebalance(etf, etfVaultAddress);
       _refundEthDust(msg.sender);

        getEtfFactory().emitVaultBalanceEvent(etfId);
    }

    error InvalidPerc();
    function changePlatformFee(uint16 newFeeBips, uint16 affUserDiscountPerc) public onlyOwner onlyActive {
        if (newFeeBips > HUNDRED_PERCENT_BIPS) revert InvalidBips();
        if (affUserDiscountPerc > 100) revert InvalidPerc();
        PLATFORM_FEE_BIPS = newFeeBips;
        AFFILIATE_USER_DISCOUNT_PERC = affUserDiscountPerc;
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