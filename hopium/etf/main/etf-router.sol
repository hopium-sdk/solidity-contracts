// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/etf/interface/imIndexFactory.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hopium/multiswap/interface/imMultiSwapRouter.sol";
import "hopium/etf/interface/imIndexPriceOracle.sol";
import "hopium/etf/interface/iEtfToken.sol";
import "hopium/common/storage/bips.sol";
import "hopium/etf/interface/iEtfVault.sol";
import "hopium/common/utils/transfer-helpers.sol";
import "hopium/common/interface/imActive.sol";

abstract contract Storage {
    uint16 public platformFee = 25;
}

abstract contract Helpers is ImMultiSwapRouter, ImEtfFactory, ImIndexPriceOracle, TransferHelpers, Storage {
    
    function _zeroSwapFees() internal pure returns (SwapFee[] memory) {
        return new SwapFee[](0);
    }

    function _swapEthToVaultTokens(Index memory index, uint256 ethAmount, address receiver, uint256 slippageBips, uint256 deadlineInSec) internal {
        SwapOrderInput[] memory inputs = new SwapOrderInput[](1);
        inputs[0] = SwapOrderInput({ tokenAddress: address(0), amount: ethAmount });

        SwapOrderOutput[] memory outputs = new SwapOrderOutput[](index.holdings.length);
        for (uint256 i = 0; i < index.holdings.length; i++) {
            outputs[i] = SwapOrderOutput({
                tokenAddress: index.holdings[i].tokenAddress,
                weightBips: index.holdings[i].weightBips
            });
        }

        getMultiSwapRouter().swap{value: ethAmount}(inputs, outputs, receiver, slippageBips, deadlineInSec, _zeroSwapFees());
    }

    function _swapVaultTokensToEth(Index memory index, uint256 etfTokenAmount, uint256 etfTokenTotalSupplyBefore, address etfVaultAddress, address receiver, uint256 slippageBips, uint256 deadlineInSec) internal {
        // Figure how many nonzero inputs we will have
        uint256 nonZeroCount = 0;
        for (uint256 i = 0; i < index.holdings.length; i++) {
            address token = index.holdings[i].tokenAddress;
            uint256 bal = IERC20(token).balanceOf(etfVaultAddress);
            uint256 withdrawAmount = (bal * etfTokenAmount) / etfTokenTotalSupplyBefore;
            if (withdrawAmount > 0) nonZeroCount++;
        }

        require(nonZeroCount > 0, "EtfRouter: nothing to withdraw");

        // Build inputs after pulling tokens here
        SwapOrderInput[] memory inputs = new SwapOrderInput[](nonZeroCount);
        uint256 k = 0;

        for (uint256 i = 0; i < index.holdings.length; i++) {
            address tokenAddress = index.holdings[i].tokenAddress;
            uint256 bal = IERC20(tokenAddress).balanceOf(etfVaultAddress);
            if (bal == 0) continue;

            uint256 withdrawAmount = (bal * etfTokenAmount) / etfTokenTotalSupplyBefore;
            if (withdrawAmount == 0) continue;

            // Ask vault to transfer tokens here
            IEtfVault(etfVaultAddress).redeem(tokenAddress, withdrawAmount, address(this));

            // Approve router to pull
            _approveMaxIfNeeded(tokenAddress, address(getMultiSwapRouter()), withdrawAmount);

            inputs[k++] = SwapOrderInput({ tokenAddress: tokenAddress, amount: withdrawAmount });
        }

        SwapOrderOutput[] memory outputs = new SwapOrderOutput[](1);
        outputs[0] = SwapOrderOutput({ tokenAddress: address(0), weightBips: uint16(HUNDRED_PERCENT_BIPS) });

        getMultiSwapRouter().swap(inputs, outputs, receiver, slippageBips, deadlineInSec, _zeroSwapFees());
    }

    function _mintEtfTokens(uint256 indexId, uint256 wethAmount, address etfTokenAddress, address receiver) internal returns (uint256) {

        uint256 etfTokenSupply = IERC20(etfTokenAddress).totalSupply();
        uint256 navWethBefore = getEtfFactory().getEtfNavWeth(indexId);

        uint256 mintAmount;
        // Mint shares at fair price:
        if (etfTokenSupply == 0) {
            // Bootstrap to index price
            uint256 p = getIndexPriceOracle().getIndexWethPrice(indexId); // WETH per 1e18-share
            require(p > 0, "EtfRouter: index price is zero");
            mintAmount = (wethAmount * 1e18) / p;
        } else {
            // shares = ethIn * supply / navBefore
            require(navWethBefore > 0, "EtfRouter: NAV is zero");
            mintAmount = (wethAmount * etfTokenSupply) / navWethBefore;
        }

        IEtfToken(etfTokenAddress).mint(receiver, mintAmount);

        return mintAmount;
    }

    function _resolveTokenAndVault(uint256 indexId) internal view returns (address, address) {
        address etfTokenAddress = getEtfFactory().getEtfTokenAddress(indexId);
        address etfVaultAddress = getEtfFactory().getEtfVaultAddress(indexId);
        require(etfTokenAddress != address(0), "EtfRouter: etfTokenAddress not deployed");
        require(etfVaultAddress != address(0), "EtfRouter: etfVaultAddress not deployed");

        return (etfTokenAddress, etfVaultAddress);
    }

    function _getPlatformVault() internal view returns (address) {
        return fetchFromDirectory("vault");
    }

    function _transferPlatformFee(uint256 amount) internal returns (uint256 netAmount) {
        address vault = _getPlatformVault();
        // If no vault set or fee is zero, nothing to do
        if (vault == address(0) || platformFee == 0) {
            return amount;
        }

        // platformFee is in bips (e.g., 50 = 0.50%)
        uint256 fee = (amount * uint256(platformFee)) / uint256(HUNDRED_PERCENT_BIPS);
        if (fee > 0) {
            _sendEth(vault, fee);
            return amount - fee;
        }
        return amount;
    }
}

contract EtfRouter is ImDirectory, ImIndexFactory, ReentrancyGuard, Helpers, ImActive  {
    constructor(address _directory) ImDirectory(_directory) {}

    event EtfTokensMinted(uint256 indexId, address caller, address receiver, uint256 etfTokenAmount, uint256 ethAmount);
    event EtfTokensRedeemed(uint256 indexId, address caller, address receiver, uint256 etfTokenAmount, uint256 ethAmount);

    //Mints tokens from Eth
    function mintEtfTokens(uint256 indexId, address receiver, uint256 slippageBips, uint256 deadlineInSec) external payable nonReentrant onlyActive  {
        require(msg.value > 0, "EtfRouter: Msg value cannot be zero");
        require(receiver != address(0), "EtfRouter: Receiver cannot be zero address");

        Index memory index = getIndexFactory().getIndexById(indexId);
        (address etfTokenAddress, address etfVaultAddress) = _resolveTokenAndVault(indexId);

        uint256 ethAmount = _transferPlatformFee(msg.value);

        // Swap eth to vault tokens and send to vault
        _swapEthToVaultTokens(index, ethAmount, etfVaultAddress, slippageBips, deadlineInSec);

        // Mint Etf tokens to receiver
        uint256 etfTokenAmount = _mintEtfTokens(indexId, ethAmount, etfTokenAddress, receiver);

        // Update Etf Volume in Etf factory
        getEtfFactory().updateEtfVolume(indexId, ethAmount);

        emit EtfTokensMinted(indexId, msg.sender, receiver, etfTokenAmount, ethAmount);
    }

    //Redeems tokens to Eth
    function redeemEtfTokens(uint256 indexId, uint256 etfTokenAmount, address payable receiver, uint256 slippageBips, uint256 deadlineInSec) external nonReentrant onlyActive {
        require(etfTokenAmount > 0, "EtfRouter: tokens to redeem should not be zero");
        require(receiver != address(0), "EtfRouter: receiver should not be zero address");

        Index memory index = getIndexFactory().getIndexById(indexId);
        (address etfTokenAddress, address etfVaultAddress) = _resolveTokenAndVault(indexId);

        // Snapshot total supply before burn
        uint256 etfTokenTotalSupplyBefore = IERC20(etfTokenAddress).totalSupply();
        require(etfTokenTotalSupplyBefore > 0, "EtfRouter: token supply is zero");
        require(etfTokenAmount <= etfTokenTotalSupplyBefore, "EtfRouter: redeemTokenAmount is greater than total supply");

        // Burn caller's Etf tokens
        IEtfToken(etfTokenAddress).burn(msg.sender, etfTokenAmount);        

        // Swap vault tokens to eth and receive here
        uint256 ethBalBefore = address(this).balance;
        _swapVaultTokensToEth(index, etfTokenAmount, etfTokenTotalSupplyBefore, etfVaultAddress, address(this), slippageBips, deadlineInSec);
        uint256 ethBalAfter = address(this).balance;

        uint256 deltaBal = ethBalAfter - ethBalBefore;
        require(deltaBal > 0, "Received eth Amount cannot be zero");
        uint256 ethAmount = _transferPlatformFee(deltaBal);

        // Send eth to receiver
        _sendEth(receiver, ethAmount);

        // Update Etf Volume in Etf factory
        getEtfFactory().updateEtfVolume(indexId, ethAmount);

        emit EtfTokensRedeemed(indexId, msg.sender, receiver, etfTokenAmount, ethAmount);
    }

    function changePlatformFee(uint16 newFee) public onlyOwner onlyActive {
        require(newFee <= HUNDRED_PERCENT_BIPS, "fee too large");
        platformFee = newFee;
    }

    function recoverAsset(address tokenAddress, address toAddress) public onlyOwner {
        _recoverAsset(tokenAddress, toAddress);
    }

    receive() external payable {}
}