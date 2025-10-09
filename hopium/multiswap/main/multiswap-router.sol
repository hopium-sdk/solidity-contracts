// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "hopium/common/storage/bips.sol";
import "hopium/multiswap/interface/iMultiSwapRouter.sol";
import "hopium/common/utils/transfer-helpers.sol";
import "hopium/common/interface/imActive.sol";

abstract contract Events {
    event FeePaid(address indexed to, uint256 amountEth);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Router02 {
    function WETH() external view returns (address);
    function factory() external view returns (address);

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

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

// -------- Custom errors --------
error ZeroAmount();
error InsufficientEth();
error InvalidToken();
error WeightZero();
error WeightsTooLarge();
error ZeroReceiver();
error BadSlippage();

abstract contract ImUniswapV2Router02 {
    IUniswapV2Router02 public immutable router;
    address public immutable WETH_ADDR;
    address public immutable FACTORY_ADDR;

    constructor(address routerAddress) {
        router = IUniswapV2Router02(routerAddress);
        // Cache once to avoid repeated external calls
        address w = IUniswapV2Router02(routerAddress).WETH();
        address f = IUniswapV2Router02(routerAddress).factory();
        WETH_ADDR = w;
        FACTORY_ADDR = f;
    }

    function getWeth() internal view returns (address) {
        return WETH_ADDR;
    }

    error QuoteUnavailable();
    function fetchQuote(uint256 amountIn, address[] memory path) internal view returns (uint) {
        // try/catch kept (behavior preserved), but use custom error to save gas on revert text
        try router.getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
            return amounts[amounts.length - 1];
        } catch {
            revert QuoteUnavailable();
        }
    }
}

abstract contract SwapHelpers is TransferHelpers, ImUniswapV2Router02 {
    address constant ZERO_ADDRESS = address(0);

    error OnlyThis();
    function _swapEthToWeth(address fromAddress, address toAddress, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (fromAddress != address(this)) revert OnlyThis();
        if (address(this).balance < amount) revert InsufficientEth();

        IWETH weth = IWETH(WETH_ADDR);
        weth.deposit{value: amount}();

        if (toAddress != address(this)) {
            _sendToken(WETH_ADDR, toAddress, amount);
        }
    }

    error InsufficientWeth();
    function _swapWethToEth(address fromAddress, address toAddress, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        IWETH weth = IWETH(WETH_ADDR);
        if (weth.balanceOf(fromAddress) < amount) revert InsufficientWeth();

        uint256 toUnwrap = amount;
        if (fromAddress != address(this)) {
            toUnwrap = _receiveToken(WETH_ADDR, amount, fromAddress);
        }

        weth.withdraw(toUnwrap);

        if (toAddress != address(this)) {
            _sendEth(toAddress, toUnwrap);
        }
    }

    error BadTokenAmount();
    function _swapTokenToToken(address fromTokenAddress, address toTokenAddress, uint256 fromAmount, address fromAddress, address toAddress, uint256 slippageBips, uint256 deadlineInSec) internal returns (uint256) {
        if (fromTokenAddress == ZERO_ADDRESS) revert InvalidToken();
        if (toTokenAddress == ZERO_ADDRESS) revert InvalidToken();
        if (fromAmount == 0) revert BadTokenAmount();

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
            unchecked { return afterBal - beforeBal; }
        }
    }

    function _swapTokenToEth(address fromTokenAddress, uint256 fromAmount, address fromAddress, address toAddress, uint256 slippageBips, uint256 deadlineInSec) internal returns (uint256) {
        if (fromTokenAddress == ZERO_ADDRESS) revert InvalidToken();
        if (fromAmount == 0) revert BadTokenAmount();

        uint256 swapAmount = fromAmount;
        if (fromAddress != address(this)) {
            swapAmount = _receiveToken(fromTokenAddress, fromAmount, fromAddress);
        }

        _approveMaxIfNeeded(fromTokenAddress, address(router), swapAmount);

        address[] memory path = _createPath(fromTokenAddress, WETH_ADDR);

        uint amountOutMin = _calcAmountOutMin(fetchQuote(swapAmount, path), slippageBips);

        uint256 beforeBal = address(toAddress).balance;

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapAmount,
            amountOutMin,
            path,
            toAddress,
            _deadline(deadlineInSec)
        );

        uint256 afterBal = address(toAddress).balance;
        unchecked { return afterBal - beforeBal; }
    }

    function _swapEthToToken(address toTokenAddress, uint256 fromAmount, address fromAddress, address toAddress, uint256 slippageBips, uint256 deadlineInSec) internal returns (uint256) {
        if (fromAddress != address(this)) revert OnlyThis();
        if (toTokenAddress == ZERO_ADDRESS) revert InvalidToken();
        if (fromAmount == 0) revert BadTokenAmount();

        uint256 swapAmount = fromAmount;

        address[] memory path = _createPath(WETH_ADDR, toTokenAddress);

        uint amountOutMin = _calcAmountOutMin(fetchQuote(swapAmount, path), slippageBips);

        uint256 beforeBal = IERC20(toTokenAddress).balanceOf(toAddress);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: swapAmount}(
            amountOutMin,
            path,
            toAddress,
            _deadline(deadlineInSec)
        );

        uint256 afterBal = IERC20(toTokenAddress).balanceOf(toAddress);
        unchecked { return afterBal - beforeBal; }
    }

    function _createPath(address from, address to) internal view returns (address[] memory path) {
        address w = WETH_ADDR;
        if (from == w || to == w) {
            path = new address[](2);
            path[0] = from;
            path[1] = to;
        } else {
            path = new address[](3);
            path[0] = from;
            path[1] = w;
            path[2] = to;
        }
    }

    function _calcAmountOutMin(uint quotedOut, uint256 slippageBips) internal pure returns (uint) {
        if (slippageBips > HUNDRED_PERCENT_BIPS) revert BadSlippage();
        // (quotedOut * (100% - bips)) / 100%
        return (quotedOut * (HUNDRED_PERCENT_BIPS - slippageBips)) / HUNDRED_PERCENT_BIPS;
    }

    function _deadline(uint256 deadlineInSec) internal view returns (uint) {
        return block.timestamp + deadlineInSec; 
    }
}

abstract contract InternalHelpers is SwapHelpers, Events {

    function _swapInputToEth(SwapOrderInput[] calldata inputs, uint256 slippageBips, uint256 deadlineInSec) internal returns (uint256) {
        address w = WETH_ADDR;
        uint256 totalEth;
        uint256 len = inputs.length;
        for (uint256 i; i < len; ) {
            address t = inputs[i].tokenAddress;
            uint256 a = inputs[i].amount;
            if (t == ZERO_ADDRESS) {
                totalEth += a;
            } else if (t == w) {
                _swapWethToEth(msg.sender, address(this), a);
            }  else {
                uint256 got = _swapTokenToEth(t, a, msg.sender, address(this), slippageBips, deadlineInSec);
                totalEth += got;
            }
            unchecked { ++i; }
        }
        return totalEth;
    }

    function _swapEthToOutput(uint256 ethAmount, SwapOrderOutput[] calldata outputs, address receiver, uint256 slippageBips, uint256 deadlineInSec) internal {
        address w = WETH_ADDR;
        uint256 len = outputs.length;

        for (uint256 i; i < len; ) {
            address outToken = outputs[i].tokenAddress;
            uint16 weight = outputs[i].weightBips;
            uint256 amount = _calcAmountFromWeight(ethAmount, weight);
            if (amount != 0) {
                if (outToken == ZERO_ADDRESS) {
                    _sendEth(receiver, amount);
                } else if (outToken == w) {
                    _swapEthToWeth(address(this), receiver, amount);
                } else {
                    _swapEthToToken(outToken, amount, address(this), receiver, slippageBips, deadlineInSec);
                }
            }
            unchecked { ++i; }
        }
    }

    function _calcAmountFromWeight(uint256 totalEthAmount, uint16 weightBips) internal pure returns (uint256) {
        return (totalEthAmount * weightBips) / HUNDRED_PERCENT_BIPS;
    }

    function _distributeFees(SwapFee[] calldata fees, uint256 totalEth) internal returns (uint256) {
        uint256 len = fees.length;
        if (len == 0) return totalEth;

        uint256 sumBips;
        for (uint256 i; i < len; ) {
            if (fees[i].feeAddress == ZERO_ADDRESS) revert ZeroReceiver();
            if (fees[i].feeBips == 0) revert WeightZero();
            sumBips += fees[i].feeBips;
            unchecked { ++i; }
        }
        if (sumBips > HUNDRED_PERCENT_BIPS) revert WeightsTooLarge();

        // Calculate total ETH to pay in fees
        uint256 totalFeeEth = (totalEth * sumBips) / HUNDRED_PERCENT_BIPS;
        if (totalFeeEth == 0) return totalEth;

        // Distribute ETH splits
        for (uint256 j; j < len; ) {
            uint256 ethAmt = (totalFeeEth * fees[j].feeBips) / sumBips;
            if (ethAmt != 0) {
                _sendEth(fees[j].feeAddress, ethAmt);
                emit FeePaid(fees[j].feeAddress, ethAmt);
            }
            unchecked { ++j; }
        }

        return totalEth - totalFeeEth;
    }

    function _refundRemaining(address toAddress) internal {
        uint256 ethBalance = address(this).balance;
        if (ethBalance != 0) {
            _sendEth(toAddress, ethBalance);
        }
    }
}

abstract contract Validations is InternalHelpers {

    error MsgValueMismatch();
    function _validateMsgValue(SwapOrderInput[] calldata inputs) internal {
        uint256 ethNeeded;
        uint256 len = inputs.length;
        for (uint i; i < len; ) {
            if (inputs[i].tokenAddress == ZERO_ADDRESS) {
                ethNeeded += inputs[i].amount;
            }
            unchecked { ++i; }
        }
        if (msg.value < ethNeeded) revert MsgValueMismatch();
    }

    function _validateWeights(SwapOrderOutput[] calldata outputs) internal pure {
        uint256 len = outputs.length;
        uint256 totalWeight;
        for (uint256 i; i < len; ) {
            if (outputs[i].weightBips == 0) revert WeightZero();
            totalWeight += outputs[i].weightBips;
            unchecked { ++i; }
        }
        if (totalWeight > HUNDRED_PERCENT_BIPS) revert WeightsTooLarge();
    }
}

contract MultiSwapRouter is Validations, ReentrancyGuard, ImDirectory, ImActive {
    constructor(address _routerAddress, address _directory) ImUniswapV2Router02(_routerAddress) ImDirectory(_directory) {}

    // -- Write fns --

    error NoInputs();
    error NoOutputs();
    function swap(SwapOrderInput[] calldata inputs, SwapOrderOutput[] calldata outputs, address receiver, uint256 slippageBips, uint256 deadlineInSec, SwapFee[] calldata fees) external payable nonReentrant onlyActive {
        if (inputs.length == 0) revert NoInputs();
        if (outputs.length == 0) revert NoOutputs();
        if (receiver == address(0)) revert ZeroReceiver();
        if (slippageBips > HUNDRED_PERCENT_BIPS) revert BadSlippage();

        _validateMsgValue(inputs);
        _validateWeights(outputs);

        //Swap inputs to Eth
        uint256 swappedEth = _swapInputToEth(inputs, slippageBips, deadlineInSec);

        //Distribute fees
        uint256 finalEthAmount = _distributeFees(fees, swappedEth);

        //Swap Eth to outputs
        _swapEthToOutput(finalEthAmount, outputs, receiver, slippageBips, deadlineInSec);

        //Refund remaining ETH
        _refundRemaining(msg.sender);
    }

    function recoverAsset(address tokenAddress, address toAddress) public onlyOwner {
        _recoverAsset(tokenAddress, toAddress);
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
