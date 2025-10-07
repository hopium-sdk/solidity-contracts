// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/etf/interface/imIndexFactory.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hopium/standalone/interface/imMultiSwapRouter.sol";
import "hopium/etf/interface/imIndexPriceOracle.sol";
import "hopium/etf/interface/iEtfToken.sol";
import "hopium/common/storage/bips.sol";
import "hopium/etf/interface/iEtfVault.sol";

abstract contract TransferHelpers {
    function _approveMaxIfNeeded(address tokenAddress, address spender, uint256 amount) internal {
        IERC20 token = IERC20(tokenAddress);
        uint256 current = token.allowance(address(this), spender);
        if (current < amount) {
            if (current != 0) {
                token.approve(spender, 0);
            }
            token.approve(spender, type(uint256).max);
        }
    }
}

abstract contract Helpers is ImMultiSwapRouter, ImEtfFactory, ImIndexPriceOracle, TransferHelpers {
    
    function _zeroSwapFees() internal pure returns (SwapFee[] memory) {
        return new SwapFee[](0);
    }

    function _executeBuySwap(Index memory index, uint256 wethAmount, address etfVaultAddress, uint256 slippageBips, uint256 deadlineInSec) internal {
        SwapOrderInput[] memory inputs = new SwapOrderInput[](1);
        inputs[0] = SwapOrderInput({ tokenAddress: address(0), amount: wethAmount });

        SwapOrderOutput[] memory outputs = new SwapOrderOutput[](index.holdings.length);
        for (uint256 i = 0; i < index.holdings.length; i++) {
            outputs[i] = SwapOrderOutput({
                tokenAddress: index.holdings[i].tokenAddress,
                weightBips: index.holdings[i].weightBips
            });
        }

        getMultiSwapRouter().swap{value: wethAmount}(inputs, outputs, etfVaultAddress, slippageBips, deadlineInSec, _zeroSwapFees());
    }

    function _executeSellSwap(Index memory index, uint256 sellTokenAmount, uint256 tokenTotalSupplyBefore, address etfVaultAddress, address receiver, uint256 slippageBips, uint256 deadlineInSec) internal {
        // Figure how many nonzero inputs we will have
        uint256 nonZeroCount = 0;
        for (uint256 i = 0; i < index.holdings.length; i++) {
            address token = index.holdings[i].tokenAddress;
            uint256 bal = IERC20(token).balanceOf(etfVaultAddress);
            uint256 withdrawAmount = (bal * sellTokenAmount) / tokenTotalSupplyBefore;
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

            uint256 withdrawAmount = (bal * sellTokenAmount) / tokenTotalSupplyBefore;
            if (withdrawAmount == 0) continue;

            // Ask vault to transfer tokens here
            IEtfVault(etfVaultAddress).withdrawToken(tokenAddress, withdrawAmount, address(this));

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
}

contract EtfRouter is ImDirectory, ImIndexFactory, ReentrancyGuard, Helpers  {
    constructor(address _directory) ImDirectory(_directory) {}

    event Buy(uint256 indexId, address caller, address receiver, uint256 tokenAmount, uint256 ethAmount);
    event Sell(uint256 indexId, address caller, address receiver, uint256 tokenAmount, uint256 ethAmount);

    function buy(uint256 indexId, address receiver, uint256 slippageBips, uint256 deadlineInSec) external payable nonReentrant  {
        require(msg.value > 0, "EtfRouter: Msg value cannot be zero");
        require(receiver != address(0), "EtfRouter: Receiver cannot be zero address");

        Index memory index = getIndexFactory().getIndexById(indexId);
        (address etfTokenAddress, address etfVaultAddress) = _resolveTokenAndVault(indexId);

        uint256 buyWethAmount = msg.value;

        // Execute swap and send tokens to vault
        _executeBuySwap(index, buyWethAmount, etfVaultAddress, slippageBips, deadlineInSec);

        // Mint Etf tokens to receiver
        uint256 mintAmount = _mintEtfTokens(indexId, buyWethAmount, etfTokenAddress, receiver);

        emit Buy(indexId, msg.sender, receiver, mintAmount, msg.value);
    }

    function sell(uint256 indexId, uint256 sellTokenAmount, address payable receiver, uint256 slippageBips, uint256 deadlineInSec) external nonReentrant {
        require(sellTokenAmount > 0, "EtfRouter: tokens to sell should not be zero");
        require(receiver != address(0), "EtfRouter: receiver should not be zero address");

        Index memory index = getIndexFactory().getIndexById(indexId);
        (address etfTokenAddress, address etfVaultAddress) = _resolveTokenAndVault(indexId);

        // Snapshot total supply before burn
        uint256 totalSupplyBefore = IERC20(etfTokenAddress).totalSupply();
        require(totalSupplyBefore > 0, "EtfRouter: token supply is zero");
        require(sellTokenAmount <= totalSupplyBefore, "EtfRouter: sellTokenAmount is greater than total supply");

        // Burn caller's Etf tokens
        IEtfToken(etfTokenAddress).burn(msg.sender, sellTokenAmount);        

        // Execute swap and send ETH to receiver
        uint256 receiverEthBalBefore = address(receiver).balance;
        _executeSellSwap(index, sellTokenAmount, totalSupplyBefore, etfVaultAddress, receiver, slippageBips, deadlineInSec);
        uint256 receiverEthBalAfter = address(receiver).balance;

        uint256 receivedEthAmount = receiverEthBalAfter - receiverEthBalBefore;

        emit Sell(indexId, msg.sender, receiver, sellTokenAmount, receivedEthAmount);
    }
}