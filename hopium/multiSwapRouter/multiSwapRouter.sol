// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

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

abstract contract TransferHelpers is ImUniswapV2Router02 {
    using SafeERC20 for IERC20;

    function _sendEth(address to, uint256 amount) internal {
        require(amount > 0, "sendEth: zero amount");
        require(address(this).balance >= amount, "sendEth: insufficient ETH");

        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "ETH send failed");
    }

    function _sendToken(address tokenAddress, address toAddress, uint256 amount) internal {
        IERC20 token = IERC20(tokenAddress);
        require(amount > 0, "sendToken: zero amount");

        token.safeTransfer(toAddress, amount);
    }

    function _receiveToken(address tokenAddress, uint256 amount, address fromAddress) internal returns (uint256) {
        IERC20 token = IERC20(tokenAddress);
        require(amount > 0, "receiveToken: zero amount");
        require(token.allowance(fromAddress, address(this)) >= amount, "receiveToken: allowance is less than amount");

        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(fromAddress, address(this), amount);
        uint256 balAfter = token.balanceOf(address(this));

        uint256 received = balAfter - balBefore;
        require(received > 0, "receiveToken: nothing received");

        return received;
    }

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

abstract contract SwapHelpers is TransferHelpers {

    address constant ZERO_ADDRESS = address(0);
    uint256 constant HUNDRED_PERCENT_BIPS = 10_000;


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
        require(fromTokenAddress != ZERO_ADDRESS, "Router: Invalid from token address");
        require(toTokenAddress != ZERO_ADDRESS, "Router: Invalid to token address");
        require(fromAmount > 0, "Router: Amount must be greater than 0");

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

contract MultiSwapRouter is SwapHelpers, ReentrancyGuard {
    constructor(address routerAddress) ImUniswapV2Router02(routerAddress) {}


    struct OrderInput {
        address tokenAddress;
        uint256 amount;
    }

    struct OrderOutput {
        address tokenAddress;
        uint16 weightBips;
    }

    struct Fee {
        address feeAddress;
        uint16 feeBips;
    }

    event Swapped(address indexed caller, OrderInput[] inputs, OrderOutput[] outputs, uint256 slippageBips, uint256 deadlineInSec, Fee[] fees);
    event FeePaid(address indexed to, uint256 amountWeth);

    function swap(OrderInput[] calldata inputs, OrderOutput[] calldata outputs, uint256 slippageBips, uint256 deadlineInSec, Fee[] calldata fees) external payable nonReentrant {
        require(inputs.length > 0, "Router: No inputs");
        require(outputs.length > 0, "Router: No outputs");

        _assertMsgValue(inputs);
        _assertWeights(outputs);

        uint256 swappedWeth = _swapInputToWeth(inputs, slippageBips, deadlineInSec);

        uint256 finalWethAmount = _distributeFees(fees, swappedWeth);

        _swapWethToOutput(finalWethAmount, outputs, slippageBips, deadlineInSec);

        _refundDust(msg.sender);

        emit Swapped(msg.sender, inputs, outputs, slippageBips, deadlineInSec, fees);
    }

    function _assertMsgValue(OrderInput[] calldata inputs) internal {
        uint256 ethNeeded;
        for (uint i; i < inputs.length; ++i) {
            if (inputs[i].tokenAddress == ZERO_ADDRESS) {
                ethNeeded += inputs[i].amount;
            }
        }
        require(msg.value >= ethNeeded, "msg.value != ETH inputs");
    }

    function _assertWeights(OrderOutput[] calldata outputs) internal pure {
        uint256 totalWeight = 0;
        for ( uint256 i = 0; i < outputs.length; i++) {
                require(outputs[i].weightBips > 0, "Router: Weight must be greater than 0");
                totalWeight += outputs[i].weightBips;
        }
        require(totalWeight <= HUNDRED_PERCENT_BIPS, "Router: Total weight must be 100%");
    }

    function _swapInputToWeth(OrderInput[] calldata inputs, uint256 slippageBips, uint256 deadlineInSec) internal returns (uint256) {
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

    function _swapWethToOutput(uint256 wethAmount, OrderOutput[] calldata outputs, uint256 slippageBips, uint256 deadlineInSec) internal {
        address wethAddress = getWeth();
        address receiver = msg.sender;

        for (uint256 i = 0; i < outputs.length; i++) {
            uint256 amount = _calcAmountFromWeight(wethAmount, outputs[i].weightBips);
            if (amount == 0) continue;

            if (outputs[i].tokenAddress == ZERO_ADDRESS) {
                _swapWethToEth(address(this), receiver, amount);
            } else if (outputs[i].tokenAddress == wethAddress) {
                _sendToken(wethAddress, receiver, amount);
            } else {
                _swapTokenToToken(wethAddress, outputs[i].tokenAddress, amount, address(this), msg.sender, slippageBips, deadlineInSec);
            }
        }

    }

    function _calcAmountFromWeight(uint256 totalWethAmount, uint16 weightBips) internal pure returns (uint256) {
        return (totalWethAmount * weightBips) / HUNDRED_PERCENT_BIPS;
    }

    function _distributeFees(Fee[] calldata fees, uint256 totalWethAmount) internal returns (uint256) {
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

    function _refundDust(address toAddress) internal {
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

    // Allow contract to receive ETH
    receive() external payable {
        require(msg.sender == getWeth(), "Direct ETH not allowed");
    }
}
