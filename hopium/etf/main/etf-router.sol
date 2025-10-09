// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/etf/interface/imIndexFactory.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "hopium/multiswap/interface/imMultiSwapRouter.sol";
import "hopium/etf/interface/imIndexPriceOracle.sol";
import "hopium/etf/interface/iEtfToken.sol";
import "hopium/common/storage/bips.sol";
import "hopium/etf/interface/iEtfVault.sol";
import "hopium/common/utils/transfer-helpers.sol";
import "hopium/common/interface/imActive.sol";
import "hopium/etf/utils/etf-addresses-helpers.sol";

uint256 constant WAD = 1e18;

// -------- Custom errors (cheaper than revert strings) --------
error ZeroMsgValue();
error ZeroReceiver();

abstract contract Storage {
    // packed-friendly size; keep as-is for behavior, but easy to co-pack later if desired
    uint16 public platformFee = 25;

    event EtfTokensMinted(uint256 indexId, address caller, address receiver, uint256 etfTokenAmount, uint256 ethAmount);
    event EtfTokensRedeemed(uint256 indexId, address caller, address receiver, uint256 etfTokenAmount, uint256 ethAmount);
}

abstract contract Helpers is ImMultiSwapRouter, ImEtfFactory, ImIndexPriceOracle, TransferHelpers, Storage, EtfAddressesHelpers {

    // Swap ETH into the index's component tokens and deliver directly to the vault
    function _swapEthToVaultTokens(Index memory index, uint256 ethAmount, address receiver, uint256 slippageBips, uint256 deadlineInSec) internal {
        SwapOrderInput[] memory inputs = new SwapOrderInput[](1);
        inputs[0] = SwapOrderInput({ tokenAddress: address(0), amount: ethAmount });

        uint256 len = index.holdings.length;
        SwapOrderOutput[] memory outputs = new SwapOrderOutput[](len);
        for (uint256 i; i < len; ) {
            outputs[i] = SwapOrderOutput({
                tokenAddress: index.holdings[i].tokenAddress,
                weightBips: index.holdings[i].weightBips
            });
            unchecked { ++i; }
        }

        // inline zero-fees array to avoid a helper call
        getMultiSwapRouter().swap{value: ethAmount}(inputs, outputs, receiver, slippageBips, deadlineInSec, new SwapFee[](0));
    }

    error NothingToWithdraw();
    // Redeem a proportional slice of vault holdings into ETH and send to `receiver`
    function _swapVaultTokensToEth(Index memory index, uint256 etfTokenAmount, uint256 etfTokenTotalSupplyBefore, address etfVaultAddress, address receiver, uint256 slippageBips, uint256 deadlineInSec) internal {
        uint256 len = index.holdings.length;

        // Read each balance once, compute withdraws once
        uint256[] memory withdraws = new uint256[](len);
        uint256 nonZeroCount;
        for (uint256 i; i < len; ) {
            address t = index.holdings[i].tokenAddress;
            uint256 bal = IERC20(t).balanceOf(etfVaultAddress);
            uint256 w = (bal * etfTokenAmount) / etfTokenTotalSupplyBefore;
            withdraws[i] = w;
            if (w != 0) nonZeroCount++;
            unchecked { ++i; }
        }

        if (nonZeroCount == 0) revert NothingToWithdraw();

        // Build inputs and pull tokens (single router addr var; no IMultiSwapRouter local)
        SwapOrderInput[] memory inputs = new SwapOrderInput[](nonZeroCount);
        address routerAddr = address(getMultiSwapRouter());

        uint256 k;
        for (uint256 i; i < len; ) {
            uint256 w = withdraws[i];
            if (w != 0) {
                address t = index.holdings[i].tokenAddress;

                IEtfVault(etfVaultAddress).redeem(t, w, address(this));
                _approveMaxIfNeeded(t, routerAddr, w);

                inputs[k++] = SwapOrderInput({ tokenAddress: t, amount: w });
            }
            unchecked { ++i; }
        }

        // Build outputs and swap to WETH
        SwapOrderOutput[] memory outputs = new SwapOrderOutput[](1);
        outputs[0] = SwapOrderOutput({
            tokenAddress: address(0),
            weightBips: uint16(HUNDRED_PERCENT_BIPS)
        });

        IMultiSwapRouter(routerAddr).swap(inputs, outputs, receiver, slippageBips, deadlineInSec, new SwapFee[](0));
    }

    error ZeroIndexPrice();
    error ZeroNav();
    // Mint ETF tokens at fair price given incoming WETH amount
    function _mintEtfTokens(uint256 indexId, uint256 wethAmount, address etfTokenAddress, address receiver) internal returns (uint256) {
        uint256 supply = IERC20(etfTokenAddress).totalSupply();
        uint256 navWethBefore = getEtfFactory().getEtfNavWeth(indexId);

        uint256 mintAmount;
        if (supply == 0) {
            // Bootstrap to index price
            uint256 p = getIndexPriceOracle().getIndexWethPrice(indexId); // WETH per 1e18-share
            if (p == 0) revert ZeroIndexPrice();
            mintAmount = (wethAmount * WAD) / p;
        } else {
            if (navWethBefore == 0) revert ZeroNav();
            // shares = ethIn * supply / navBefore
            mintAmount = (wethAmount * supply) / navWethBefore;
        }

        IEtfToken(etfTokenAddress).mint(receiver, mintAmount);
        return mintAmount;
    }

    function _resolveTokenAndVault(uint256 indexId) internal view returns (address etfTokenAddress, address etfVaultAddress) {
        etfTokenAddress = _getEtfTokenAddress(indexId);
        etfVaultAddress = _getEtfVaultAddress(indexId);
        if (etfTokenAddress == address(0)) revert ZeroReceiver(); // reuse small error to save bytecode (semantically: missing address)
        if (etfVaultAddress == address(0)) revert ZeroReceiver();
    }

    function _transferPlatformFee(uint256 amount) internal returns (uint256 netAmount) {
        address vault = fetchFromDirectory("vault");
        uint16 feeBips = platformFee;

        if (vault == address(0) || feeBips == 0) return amount;

        uint256 fee = (amount * uint256(feeBips)) / uint256(HUNDRED_PERCENT_BIPS);
        if (fee != 0) {
            _sendEth(vault, fee);
            return amount - fee;
        }
        return amount;
    }
}

contract EtfRouter is ImDirectory, ImIndexFactory, ReentrancyGuard, Helpers, ImActive {
    constructor(address _directory) ImDirectory(_directory) {}

    // -------- Mint from ETH --------
    function mintEtfTokens(uint256 indexId, address receiver, uint256 slippageBips, uint256 deadlineInSec) external payable nonReentrant onlyActive {
        if (msg.value == 0) revert ZeroMsgValue();
        if (receiver == address(0)) revert ZeroReceiver();

        Index memory index = getIndexFactory().getIndexById(indexId);
        (address etfTokenAddress, address etfVaultAddress) = _resolveTokenAndVault(indexId);

        uint256 ethAmount = _transferPlatformFee(msg.value);

        // Swap ETH -> component tokens to the vault
        _swapEthToVaultTokens(index, ethAmount, etfVaultAddress, slippageBips, deadlineInSec);

        // Mint ETF tokens
        uint256 etfTokenAmount = _mintEtfTokens(indexId, ethAmount, etfTokenAddress, receiver);

        // Emit volume event on etf factory
        getEtfFactory().emitEtfVolumeEvent(indexId, ethAmount);

        emit EtfTokensMinted(indexId, msg.sender, receiver, etfTokenAmount, ethAmount);
    }

    error SupplyZero();
    error RedeemTooLarge();
    // -------- Redeem to ETH --------
    function redeemEtfTokens(uint256 indexId, uint256 etfTokenAmount, address payable receiver, uint256 slippageBips, uint256 deadlineInSec) external nonReentrant onlyActive {
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
        _swapVaultTokensToEth(index, etfTokenAmount, supplyBefore, etfVaultAddress, address(this), slippageBips, deadlineInSec);
        uint256 ethBalAfter = address(this).balance;

        uint256 deltaBal = ethBalAfter - ethBalBefore;
        if (deltaBal == 0) revert ZeroMsgValue();

        // Platform fee (if any), then send ETH to receiver
        uint256 ethAmount = _transferPlatformFee(deltaBal);
        _sendEth(receiver, ethAmount);

        // Emit volume event on etf factory
        getEtfFactory().emitEtfVolumeEvent(indexId, ethAmount);

        emit EtfTokensRedeemed(indexId, msg.sender, receiver, etfTokenAmount, ethAmount);
    }

    error FeeTooLarge();
    function changePlatformFee(uint16 newFee) public onlyOwner onlyActive {
        if (newFee > HUNDRED_PERCENT_BIPS) revert FeeTooLarge();
        platformFee = newFee;
    }

    function recoverAsset(address tokenAddress, address toAddress) public onlyOwner {
        _recoverAsset(tokenAddress, toAddress);
    }

    receive() external payable {}
}
