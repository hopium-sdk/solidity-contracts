// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/etf/interface/imIndexFactory.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "hopium/uniswap/interface/imMultiSwapRouter.sol";
import "hopium/etf/interface/imIndexPriceOracle.sol";
import "hopium/etf/interface/iEtfToken.sol";
import "hopium/common/types/bips.sol";
import "hopium/etf/interface/iEtfVault.sol";
import "hopium/common/lib/transfer-helpers.sol";
import "hopium/common/interface/imActive.sol";

uint256 constant WAD = 1e18;

// -------- Custom errors (cheaper than revert strings) --------
error ZeroMsgValue();
error ZeroReceiver();
error InvalidBips();

abstract contract Storage {
    // packed-friendly size; keep as-is for behavior, but easy to co-pack later if desired
    uint16 public platformFee = 25;

    event EtfTokensMinted(uint256 indexId, address caller, address receiver, uint256 etfTokenAmount, uint256 ethAmount);
    event EtfTokensRedeemed(uint256 indexId, address caller, address receiver, uint256 etfTokenAmount, uint256 ethAmount);
}

abstract contract Helpers is ImMultiSwapRouter, ImEtfFactory, ImIndexPriceOracle, Storage {

    // Swap ETH into the index's component tokens and deliver directly to the vault
    function _swapEthToVaultTokens(
        Index memory index,
        uint256 ethAmount,
        address receiverVault,
        uint32 slippageBips
    ) internal {
        uint256 len = index.holdings.length;
        if (len == 0) return;

        MultiTokenOutput[] memory outputs = new MultiTokenOutput[](len);
        unchecked {
            for (uint256 i; i < len; ++i) {
                outputs[i] = MultiTokenOutput({
                    tokenAddress: index.holdings[i].tokenAddress,
                    weightBips: index.holdings[i].weightBips
                });
            }
        }

        getMultiSwapRouter().swapEthToMultipleTokens{value: ethAmount}(
            outputs,
            receiverVault,
            slippageBips
        );
    }

    error NothingToWithdraw();
    // Redeem a proportional slice of vault holdings into ETH and send to `receiver`
    function _swapVaultTokensToEth(
        Index memory index,
        uint256 etfTokenAmount,
        uint256 etfTokenTotalSupplyBefore,
        address etfVaultAddress,
        address payable receiver,
        uint32 slippageBips
    ) internal {
        uint256 len = index.holdings.length;

        // Compute proportional withdraw amounts
        uint256[] memory withdraws = new uint256[](len);
        uint256 nonZeroCount;
        unchecked {
            for (uint256 i; i < len; ++i) {
                address t = index.holdings[i].tokenAddress;
                uint256 bal = IERC20(t).balanceOf(etfVaultAddress);
                uint256 w = (bal * etfTokenAmount) / etfTokenTotalSupplyBefore;
                withdraws[i] = w;
                if (w != 0) ++nonZeroCount;
            }
        }
        if (nonZeroCount == 0) revert NothingToWithdraw();

        // Redeem each non-zero token amount straight to the MultiswapEthRouter
        IMultiSwapRouter multiSwapRouter = getMultiSwapRouter();
        address routerAddr = address(multiSwapRouter);
        MultiTokenInput[] memory inputs = new MultiTokenInput[](nonZeroCount);
        uint256 k;
        unchecked {
            for (uint256 i; i < len; ++i) {
                uint256 w = withdraws[i];
                if (w == 0) continue;
                address t = index.holdings[i].tokenAddress;

                // send tokens to the router so it already holds them
                IEtfVault(etfVaultAddress).redeem(t, w, routerAddr);

                inputs[k++] = MultiTokenInput({ tokenAddress: t, amount: w });
            }
        }

        // Router already has the tokens -> preTransferred = true
        multiSwapRouter.swapMultipleTokensToEth(
            inputs,
            receiver,
            slippageBips,
            true
        );
    }

    error ZeroIndexPrice();
    error ZeroNav();
    // Calculate ETF tokens to mint at fair price given incoming WETH amount
    function _calcMintAmount(
        uint256 indexId,
        uint256 wethAmount,
        address etfTokenAddress
    ) internal view returns (uint256 mintAmount) {
        // Snapshot current supply and NAV before any deposits/swaps
        uint256 supplyBefore = IERC20(etfTokenAddress).totalSupply();

        if (supplyBefore == 0) {
            // Bootstrap to oracle index price (WETH per 1e18 ETF share)
            uint256 priceWeth = getIndexPriceOracle().getIndexWethPrice(indexId);
            if (priceWeth == 0) revert ZeroIndexPrice();
            // shares = ethIn * 1e18 / price
            mintAmount = (wethAmount * WAD) / priceWeth;
        } else {
            uint256 navWethBefore = getEtfFactory().getEtfNavWeth(indexId);
            if (navWethBefore == 0) revert ZeroNav();
            // Fair-mint: shares = ethIn * supplyBefore / navBefore
            mintAmount = (wethAmount * supplyBefore) / navWethBefore;
        }
    }

    function _resolveTokenAndVault(uint256 indexId) internal view returns (address etfTokenAddress, address etfVaultAddress) {
        etfTokenAddress = getEtfFactory().getEtfTokenAddress(indexId);
        etfVaultAddress =  getEtfFactory().getEtfVaultAddress(indexId);
        if (etfTokenAddress == address(0)) revert ZeroReceiver(); // reuse small error to save bytecode (semantically: missing address)
        if (etfVaultAddress == address(0)) revert ZeroReceiver();
    }

    function _transferPlatformFee(uint256 amount) internal returns (uint256 netAmount) {
        address vault = fetchFromDirectory("vault");
        uint16 feeBips = platformFee;

        if (vault == address(0) || feeBips == 0) return amount;

        uint256 fee = (amount * uint256(feeBips)) / uint256(HUNDRED_PERCENT_BIPS);
        if (fee != 0) {
            TransferHelpers.sendEth(vault, fee);
            return amount - fee;
        }
        return amount;
    }
}

contract EtfRouter is ImDirectory, ImIndexFactory, ReentrancyGuard, Helpers, ImActive {
    constructor(address _directory) ImDirectory(_directory) {}

    uint32 public DEFAULT_SLIPPAGE_BIPS = 300;


    // -------- Mint from ETH --------
    function mintEtfTokens(uint256 indexId, address receiver) external payable nonReentrant onlyActive {
        if (msg.value == 0) revert ZeroMsgValue();
        if (receiver == address(0)) revert ZeroReceiver();

        Index memory index = getIndexFactory().getIndexById(indexId);
        (address etfTokenAddress, address etfVaultAddress) = _resolveTokenAndVault(indexId);

        // Net ETH after platform fee
        uint256 ethAmount = _transferPlatformFee(msg.value);

        // Compute mint amount from the pre-swap snapshot (inside helper)
        uint256 etfTokenAmount = _calcMintAmount(indexId, ethAmount, etfTokenAddress);

        // Swap ETH -> component tokens into the vault
        _swapEthToVaultTokens(index, ethAmount, etfVaultAddress, DEFAULT_SLIPPAGE_BIPS);

        // Mint ETF tokens to receiver
        IEtfToken(etfTokenAddress).mint(receiver, etfTokenAmount);

        // Update factory volume metrics
        getEtfFactory().updateEtfVolume(indexId, ethAmount);

        emit EtfTokensMinted(indexId, msg.sender, receiver, etfTokenAmount, ethAmount);
    }

    error SupplyZero();
    error RedeemTooLarge();
    // -------- Redeem to ETH --------
    function redeemEtfTokens(uint256 indexId, uint256 etfTokenAmount, address payable receiver) external nonReentrant onlyActive {
        if (etfTokenAmount == 0) revert ZeroMsgValue();
        if (receiver == address(0)) revert ZeroReceiver();

        Index memory index = getIndexFactory().getIndexById(indexId);
        (address etfTokenAddress, address etfVaultAddress) = _resolveTokenAndVault(indexId);

        // Snapshot total supply before burn
        uint256 supplyBefore = IERC20(etfTokenAddress).totalSupply();
        if (supplyBefore == 0) revert SupplyZero();
        if (etfTokenAmount > supplyBefore) revert RedeemTooLarge();

        // Burn caller's ETF tokens
        IEtfToken(etfTokenAddress).burn(msg.sender, etfTokenAmount);

        // Swap vault tokens -> ETH to this router
        uint256 ethBalBefore = address(this).balance;
        _swapVaultTokensToEth(index, etfTokenAmount, supplyBefore, etfVaultAddress, payable(address(this)), DEFAULT_SLIPPAGE_BIPS);
        uint256 ethBalAfter = address(this).balance;

        uint256 deltaBal = ethBalAfter - ethBalBefore;
        if (deltaBal == 0) revert ZeroMsgValue();

        // Platform fee (if any), then send ETH to receiver
        uint256 ethAmount = _transferPlatformFee(deltaBal);
        TransferHelpers.sendEth(receiver, ethAmount);

        // Emit volume event on etf factory
        getEtfFactory().updateEtfVolume(indexId, ethAmount);

        emit EtfTokensRedeemed(indexId, msg.sender, receiver, etfTokenAmount, ethAmount);
    }

    function changePlatformFee(uint16 newFee) public onlyOwner onlyActive {
        if (newFee > HUNDRED_PERCENT_BIPS) revert InvalidBips();
        platformFee = newFee;
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
