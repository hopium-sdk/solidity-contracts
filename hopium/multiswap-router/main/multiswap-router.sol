// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "hopium/common/storage/bips.sol";
import "hopium/multiswap-router/interface/iMultiSwapRouter.sol";
import "hopium/common/utils/transfer-helpers.sol";

abstract contract Events {
    event Swapped(address indexed caller, SwapOrderInput[] inputs, SwapOrderOutput[] outputs, uint256 slippageBips, uint256 deadlineInSec, SwapFee[] fees);
    event FeePaid(address indexed to, uint256 amountWeth);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
    function factory() external pure returns (address);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function getAmountsOut(
        uint amountIn,
        address[] memory path
    ) external view returns (uint[] memory amounts);
}

abstract contract ImUniswapV2Router02 {
    IUniswapV2Router02 public immutable router;

    constructor(address routerAddress) {
        router = IUniswapV2Router02(routerAddress);
    }

    function getWeth() internal view returns (address) {
        return router.WETH();
    }

    function fetchQuote(uint256 amountIn, address[] memory path) internal view returns (uint) {
        try router.getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
            return amounts[amounts.length - 1];
        } catch {
            revert("Uniswap Router: Quote unavailable: path/liquidity");
        }
    }
}

abstract contract SwapHelpers is TransferHelpers,ImUniswapV2Router02 {

    address constant ZERO_ADDRESS = address(0);

    function _swapEthToWeth(address fromAddress, address toAddress, uint256 amount) internal {
        address wethAddress = getWeth();
        require(amount > 0, "wrap: zero amount");
        require(fromAddress == address(this), "wrap: only this contract can wrap ETH");
        require(address(this).balance >= amount, "WETH: insufficient ETH");

        IWETH Weth = IWETH(wethAddress);
        Weth.deposit{value: amount}();

        if (toAddress != address(this)) {
            _sendToken(wethAddress, toAddress, amount);
        }
    }

    function _swapWethToEth(address fromAddress, address toAddress, uint256 amount) internal {
        address wethAddress = getWeth();
        IWETH Weth = IWETH(wethAddress);
        require(amount > 0, "unwrap: zero amount");
        require(Weth.balanceOf(fromAddress) >= amount, "WETH: insufficient WETH");

        uint256 toUnwrap = amount;
        if (fromAddress != address(this)) {
            toUnwrap = _receiveToken(wethAddress, amount, fromAddress);
        }

        Weth.withdraw(toUnwrap);

        if (toAddress != address(this)) {
            _sendEth(toAddress, toUnwrap);
        }
    }

    function _swapTokenToToken(address fromTokenAddress, address toTokenAddress, uint256 fromAmount, address fromAddress, address toAddress, uint256 slippageBips, uint256 deadlineInSec) internal returns (uint256) {
        require(fromTokenAddress != ZERO_ADDRESS, "MultiSwap Router: Invalid from token address");
        require(toTokenAddress != ZERO_ADDRESS, "MultiSwap Router: Invalid to token address");
        require(fromAmount > 0, "MultiSwap Router: Amount must be greater than 0");

        uint256 swapAmount = fromAmount;
        if (fromAddress != address(this)) {
            swapAmount = _receiveToken(fromTokenAddress, fromAmount, fromAddress);
        }

        if (fromTokenAddress == toTokenAddress) {
            _sendToken(fromTokenAddress, toAddress, swapAmount);
            return swapAmount;
        } else {
            _approveMaxIfNeeded(fromTokenAddress, address(router), swapAmount);

            address[] memory path = _createPath(fromTokenAddress, toTokenAddress);

            uint amountOutMin = _calcAmountOutMin(fetchQuote(swapAmount, path), slippageBips);

            uint256 beforeBal = IERC20(toTokenAddress).balanceOf(toAddress);

            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                swapAmount,
                amountOutMin,
                path,
                toAddress,
                _deadline(deadlineInSec)
            );

            uint256 afterBal = IERC20(toTokenAddress).balanceOf(toAddress);
            uint256 received = afterBal - beforeBal;
            
            return received;
        }
    }

    function _createPath(address from, address to) internal view returns (address[] memory path) {
        address wethAddress = getWeth();

        if (from == wethAddress || to == wethAddress) {
            // direct 2-token path
            path = new address[](2);
            path[0] = from;
            path[1] = to;
        } else {
            // route through WETH
            path = new address[](3);
            path[0] = from;
            path[1] = wethAddress;
            path[2] = to;
        }
    }

    function _calcAmountOutMin(uint quotedOut, uint256 slippageBips) internal pure returns (uint) {
        require(slippageBips <= HUNDRED_PERCENT_BIPS, "slippageBips > 100%");

        return (quotedOut * (HUNDRED_PERCENT_BIPS - slippageBips)) / HUNDRED_PERCENT_BIPS;
    }

    function _deadline(uint256 deadlineInSec) internal view returns (uint) {
        return block.timestamp + deadlineInSec;
    }
}

abstract contract InternalHelpers is SwapHelpers, Events {

    function _swapInputToWeth(SwapOrderInput[] calldata inputs, uint256 slippageBips, uint256 deadlineInSec) internal returns (uint256) {
        uint256 totalWeth = 0;
        for (uint256 i = 0; i < inputs.length; i++) {
            if (inputs[i].tokenAddress == ZERO_ADDRESS) {
                _swapEthToWeth(address(this), address(this), inputs[i].amount);
                totalWeth += inputs[i].amount;
            } else {
                uint256 swappedWeth = _swapTokenToToken(inputs[i].tokenAddress, getWeth(), inputs[i].amount, msg.sender, address(this), slippageBips, deadlineInSec);
                totalWeth += swappedWeth;
            }
        }

        return totalWeth;
    }

    function _swapWethToOutput(uint256 wethAmount, SwapOrderOutput[] calldata outputs, address receiver, uint256 slippageBips, uint256 deadlineInSec) internal {
        address wethAddress = getWeth();

        for (uint256 i = 0; i < outputs.length; i++) {
            uint256 amount = _calcAmountFromWeight(wethAmount, outputs[i].weightBips);
            if (amount == 0) continue;

            if (outputs[i].tokenAddress == ZERO_ADDRESS) {
                _swapWethToEth(address(this), receiver, amount);
            } else if (outputs[i].tokenAddress == wethAddress) {
                _sendToken(wethAddress, receiver, amount);
            } else {
                _swapTokenToToken(wethAddress, outputs[i].tokenAddress, amount, address(this), receiver, slippageBips, deadlineInSec);
            }
        }

    }

    function _calcAmountFromWeight(uint256 totalWethAmount, uint16 weightBips) internal pure returns (uint256) {
        return (totalWethAmount * weightBips) / HUNDRED_PERCENT_BIPS;
    }

    function _distributeFees(SwapFee[] calldata fees, uint256 totalWethAmount) internal returns (uint256) {
        if (fees.length == 0) return totalWethAmount;

        uint256 sumBips = 0;
        for (uint256 i = 0; i < fees.length; i++) {
            require(fees[i].feeAddress != ZERO_ADDRESS, "Fee: zero address");
            require(fees[i].feeBips > 0, "Fee: zero bips");
            sumBips += fees[i].feeBips;
        }
        require(sumBips <= HUNDRED_PERCENT_BIPS, "Fee: > 100%");

        uint256 remaining = totalWethAmount;

        for (uint256 i = 0; i < fees.length; i++) {
            uint256 amount = _calcAmountFromWeight(totalWethAmount, fees[i].feeBips);

            if (amount == 0) continue; // tiny shares
            
            _swapWethToEth(address(this), fees[i].feeAddress, amount);
            remaining -= amount; // safe: sum(amounts) <= totalWethAmount

            emit FeePaid(fees[i].feeAddress, amount);
        }

        return remaining;
    }

    function _refundRemaining(address toAddress) internal {
        uint256 wethBalance = IWETH(getWeth()).balanceOf(address(this));
        uint256 ethBalance = address(this).balance;

        // If we have leftover WETH, unwrap and send as ETH to user
        if (wethBalance > 0) {
            _swapWethToEth(address(this), toAddress, wethBalance);
        }

        // If we also have leftover raw ETH (from rounding, refunds, etc.), send it too
        if (ethBalance > 0) {
            _sendEth(toAddress, ethBalance);
        }
    }
}

abstract contract Validations is InternalHelpers {
    function _validateMsgValue(SwapOrderInput[] calldata inputs) internal {
        uint256 ethNeeded;
        for (uint i; i < inputs.length; ++i) {
            if (inputs[i].tokenAddress == ZERO_ADDRESS) {
                ethNeeded += inputs[i].amount;
            }
        }
        require(msg.value >= ethNeeded, "msg.value != ETH inputs");
    }

    function _validateWeights(SwapOrderOutput[] calldata outputs) internal pure {
        uint256 totalWeight = 0;
        for ( uint256 i = 0; i < outputs.length; i++) {
                require(outputs[i].weightBips > 0, "MultiSwap Router: Weight must be greater than 0");
                totalWeight += outputs[i].weightBips;
        }
        require(totalWeight <= HUNDRED_PERCENT_BIPS, "MultiSwap Router: Total weight must be 100%");
    }
}

contract MultiSwapRouter is Validations, ReentrancyGuard, ImDirectory {
    constructor(address routerAddress, address _directory) ImUniswapV2Router02(routerAddress) ImDirectory(_directory) {}

    // -- Write fns --

    function swap(SwapOrderInput[] calldata inputs, SwapOrderOutput[] calldata outputs, address receiver, uint256 slippageBips, uint256 deadlineInSec, SwapFee[] calldata fees) external payable nonReentrant {
        require(inputs.length > 0, "MultiSwap Router: No inputs");
        require(outputs.length > 0, "MultiSwap Router: No outputs");
        require(receiver != address(0), "MultiSwap Router: Receiver cannot be zero address");
        require(slippageBips <= HUNDRED_PERCENT_BIPS, "MultiSwap Router: bad slippage");

        _validateMsgValue(inputs);
        _validateWeights(outputs);

        uint256 swappedWeth = _swapInputToWeth(inputs, slippageBips, deadlineInSec);

        uint256 finalWethAmount = _distributeFees(fees, swappedWeth);

        _swapWethToOutput(finalWethAmount, outputs, receiver, slippageBips, deadlineInSec);

        _refundRemaining(msg.sender);

        emit Swapped(msg.sender, inputs, outputs, slippageBips, deadlineInSec, fees);
    }

    function withdraw(address tokenAddress, address toAddress) public onlyOwner {
        _withdraw(tokenAddress, toAddress);
    }

    // Allow contract to receive ETH
    receive() external payable {
        require(msg.sender == getWeth(), "Direct ETH not allowed");
    }
}
