// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "hopium/common/interface/imDirectory.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "hopium/uniswap/types/multiswap.sol";
import "hopium/common/types/bips.sol";

import "hopium/common/lib/transfer-helpers.sol";
import "hopium/common/interface-ext/iWeth.sol";
import "hopium/common/lib/permit2.sol";

import "hopium/uniswap/lib/oracleLibrary.sol";
import "hopium/uniswap/interface/imPoolFinder.sol";

import "hopium/uniswap/interface-ext/uniswapV2.sol";
import "hopium/uniswap/interface-ext/uniswapV3.sol";
import "hopium/uniswap/interface-ext/universal-router.sol";

/* ----------------------------------------------------- */
/*                  Custom errors (cheaper)              */
/* ----------------------------------------------------- */
error ZeroAddress();
error InvalidInput();
error WeightsInvalid();
error NoPoolFound();
error InvalidSlippage();

/* ----------------------------------------------------- */
/*                        Storage                        */
/* ----------------------------------------------------- */
abstract contract Storage {
    address public immutable wethAddress;

    IPermit2 public immutable permit2; 

    IUniswapV2Factory public immutable v2Factory;
    IUniswapV3Factory public immutable v3Factory;

    IUniswapV2Router02 public immutable v2Router;   // read-only getAmountsOut
    IUniversalRouter    public immutable uRouter;   // actual swaps

    constructor(
        address _v2Router,
        address _v3Factory,
        address _universalRouter,
        address _permit2
    ) {
        if (_v3Factory == address(0)) revert ZeroAddress();
        if (_v2Router  == address(0)) revert ZeroAddress();
        if (_universalRouter == address(0)) revert ZeroAddress();
        if (_permit2 == address(0)) revert ZeroAddress();

        v3Factory = IUniswapV3Factory(_v3Factory);
        v2Router  = IUniswapV2Router02(_v2Router);
        uRouter   = IUniversalRouter(_universalRouter);

        address _weth = IUniswapV2Router02(_v2Router).WETH();
        wethAddress = _weth;
        v2Factory   = IUniswapV2Factory(IUniswapV2Router02(_v2Router).factory());

        permit2 = IPermit2(_permit2);
    }
}

/* ----------------------------------------------------- */
/*                      Quote helpers                    */
/* ----------------------------------------------------- */
error QuoteUnavailable();
abstract contract QuoteHelpers is Storage, ImDirectory {
    function _applySlippage(uint256 quoteOut, uint32 slippageBps) internal pure returns (uint256) {
        if (slippageBps > HUNDRED_PERCENT_BIPS) revert WeightsInvalid();
        return (quoteOut * (HUNDRED_PERCENT_BIPS - slippageBps)) / HUNDRED_PERCENT_BIPS;
    }

    /// @dev V2 minOut calc using Router.getAmountsOut (read-only use)
    /// @dev V2 minOut calc using Router.getAmountsOut (cheap view).
    ///      For fee-on-transfer tokens, this is only an estimate (the router can’t know transfer fees).
    function _calcMinOutV2(
        address tokenInAddress,
        address tokenOutAddress,
        uint256 amountIn,
        uint32  slippageBps
    ) internal view returns (uint256 minOut) {
        if (amountIn == 0) return 0;
        if (tokenInAddress == address(0) || tokenOutAddress == address(0)) revert ZeroAddress();
        if (slippageBps > HUNDRED_PERCENT_BIPS) revert WeightsInvalid();

        address[] memory path = new address[](2);
        path[0] = tokenInAddress;
        path[1] = tokenOutAddress;

        uint256[] memory amounts;
        // some routers may revert if pair doesn’t exist; catch and signal unavailability
        try v2Router.getAmountsOut(amountIn, path) returns (uint256[] memory outAmts) {
            amounts = outAmts;
        } catch {
            revert QuoteUnavailable();
        }

        if (amounts.length < 2) revert QuoteUnavailable();
        uint256 quoteOut = amounts[1];
        if (quoteOut == 0) revert QuoteUnavailable();

        minOut = _applySlippage(quoteOut, slippageBps);
    }

    /// @dev V3 minOut calc using pool TWAP/spot — no Quoter simulation gas.
    ///      - Applies fee-on-input (1e6 denominator) before pricing.
    ///      - Uses a short TWAP (e.g., 15s), falling back to spot tick if oracle is too young.
    ///      NOTE: Ignores your own price impact; use conservative slippage for large trades.
    function _calcMinOutV3(
        address tokenInAddress,
        address tokenOutAddress,
        uint24  fee,           // 500, 3000, 10000, etc.
        uint256 amountIn,
        uint32  slippageBps
    ) internal view returns (uint256 minOut) {
        if (amountIn == 0) return 0;
        if (tokenInAddress == address(0) || tokenOutAddress == address(0)) revert ZeroAddress();
        if (slippageBps > HUNDRED_PERCENT_BIPS) revert WeightsInvalid();

        address pool = v3Factory.getPool(tokenInAddress, tokenOutAddress, fee);
        if (pool == address(0)) revert NoPoolFound();

        // Uniswap V3 takes fee from amountIn
        uint256 amountAfterFee = (amountIn * (1_000_000 - uint256(fee))) / 1_000_000;
        if (amountAfterFee == 0) revert QuoteUnavailable();

        // Cap to uint128 as required by OracleLibrary.getQuoteAtTick
        uint128 amt128 = amountAfterFee > type(uint128).max ? type(uint128).max : uint128(amountAfterFee);

        // Choose a short, cheap TWAP window (adjust if you like)
        uint32 secondsAgo = 15;

        // Derive a tick to quote at: prefer TWAP, fall back to spot
        int24 tickForQuote;
        {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = secondsAgo; // older
            secondsAgos[1] = 0;          // now

            // try TWAP via external call (try/catch allowed)
            try IUniswapV3Pool(pool).observe(secondsAgos) returns (
                int56[] memory tickCumulatives,
                uint160[] memory /* secondsPerLiquidityCumulativeX128s */
            ) {
                tickForQuote = OracleLibrary.meanTickFromCumulatives(
                    tickCumulatives[0],
                    tickCumulatives[1],
                    secondsAgo
                );
            } catch {
                // not enough observations (young/idle pool) — use spot tick
                (, int24 spotTick, , , , , ) = IUniswapV3Pool(pool).slot0();
                tickForQuote = spotTick;
            }
        }

        uint256 quoteOut = OracleLibrary.getQuoteAtTick(
            tickForQuote,
            amt128,
            tokenInAddress,
            tokenOutAddress
        );
        if (quoteOut == 0) revert QuoteUnavailable();

        // Apply user slippage tolerance
        minOut = _applySlippage(quoteOut, slippageBps);
    }
}

/* ----------------------------------------------------- */
/*                 Universal Router swapper              */
/* ----------------------------------------------------- */
abstract contract URSwapHelpers is QuoteHelpers {
    // Command bytes (from Uniswap’s Commands.sol)
    uint256 constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint256 constant CMD_V2_SWAP_EXACT_IN = 0x08;

    /* ---------------------- Packing helpers ----------------------- */
    // inputs for V3_SWAP_EXACT_IN = abi.encode(recipient, amountIn, amountOutMin, path, payerIsUser)
    function _packV3ExactInInput(
        address tokenInAddress,
        address tokenOutAddress,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipientAddress
    ) internal returns (bytes memory input) {
        TransferHelpers.approveMaxIfNeeded(tokenInAddress, address(permit2), amountIn);
        Permit2.approveMaxIfNeededPermit2(address(permit2), tokenInAddress, address(uRouter), uint160(amountIn));
        bytes memory path = abi.encodePacked(tokenInAddress, fee, tokenOutAddress);
        input = abi.encode(recipientAddress, amountIn, amountOutMin, path, true);
    }

    // inputs for V2_SWAP_EXACT_IN = abi.encode(recipient, amountIn, amountOutMin, path[], payerIsUser)
    function _packV2ExactInInput(
        address tokenInAddress,
        address tokenOutAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipientAddress
    ) internal returns (bytes memory input) {
        TransferHelpers.approveMaxIfNeeded(tokenInAddress, address(permit2), amountIn);
        Permit2.approveMaxIfNeededPermit2(address(permit2), tokenInAddress, address(uRouter), uint160(amountIn));
        address[] memory path = new address[](2);
        path[0] = tokenInAddress;
        path[1] = tokenOutAddress;
        input = abi.encode(recipientAddress, amountIn, amountOutMin, path, true);
    }

    error NoSwaps();
    // Execute a built batch
    function _executeBatch(bytes memory commands, bytes[] memory inputs, uint256 count) internal {
        if (count == 0) revert NoSwaps();

        // Trim inputs array length if over-allocated
        if (inputs.length != count) {
            bytes[] memory trimmed = new bytes[](count);
            unchecked {
                for (uint256 i = 0; i < count; ++i) trimmed[i] = inputs[i];
            }
            inputs = trimmed;
        }

        // Trim commands length in-place (cheapest)
        assembly {
            mstore(commands, count)
        }

        uRouter.execute(commands, inputs);
    }
}

/* ----------------------------------------------------- */
/*            Token <-> WETH packed-leg builders         */
/* ----------------------------------------------------- */
abstract contract TokenEthSwapHelpers is URSwapHelpers, ImPoolFinder {
    /// @notice Build a WETH->token swap leg (no execute).
    function _packWethToTokenSwap(
        address tokenAddress,
        uint256 wethAmount,
        address recipientAddress,
        uint32 slippageBps
    ) internal returns (bytes1 cmd, bytes memory packedInput) {
        if (wethAmount == 0) return (bytes1(0), bytes(""));
         Pool memory pool = getPoolFinder().getBestWethPoolUpdatable(tokenAddress);
        if (pool.poolAddress == address(0)) revert NoPoolFound();

        uint256 minOut;
        if (pool.isV3Pool == 1) {
            minOut = _calcMinOutV3(wethAddress, tokenAddress, pool.poolFee, wethAmount, slippageBps);
            packedInput = _packV3ExactInInput(wethAddress, tokenAddress, pool.poolFee, wethAmount, minOut, recipientAddress);
            cmd = bytes1(uint8(CMD_V3_SWAP_EXACT_IN));
        } else {
            minOut = _calcMinOutV2(wethAddress, tokenAddress, wethAmount, slippageBps);
            packedInput = _packV2ExactInInput(wethAddress, tokenAddress, wethAmount, minOut, recipientAddress);
            cmd = bytes1(uint8(CMD_V2_SWAP_EXACT_IN));
        }
    }

    /// @notice Build a token->WETH swap leg (no execute). Assumes tokens are already held by this contract.
    function _packTokenToWethSwap(
        address tokenAddress,
        uint256 amountIn,
        address recipientAddress,
        uint32 slippageBps
    ) internal returns (bytes1 cmd, bytes memory packedInput) {
        if (amountIn == 0) return (bytes1(0), bytes(""));
        if (tokenAddress == address(0) || tokenAddress == wethAddress) revert BadToken();

        Pool memory pool = getPoolFinder().getBestWethPoolUpdatable(tokenAddress);
        if (pool.poolAddress == address(0)) revert NoPoolFound();

        uint256 minOut;
        if (pool.isV3Pool == 1) {
            minOut = _calcMinOutV3(tokenAddress, wethAddress, pool.poolFee, amountIn, slippageBps);
            packedInput = _packV3ExactInInput(tokenAddress, wethAddress, pool.poolFee, amountIn, minOut, recipientAddress);
            cmd = bytes1(uint8(CMD_V3_SWAP_EXACT_IN));
        } else {
            minOut = _calcMinOutV2(tokenAddress, wethAddress, amountIn, slippageBps);
            packedInput = _packV2ExactInInput(tokenAddress, wethAddress, amountIn, minOut, recipientAddress);
            cmd = bytes1(uint8(CMD_V2_SWAP_EXACT_IN));
        }
    }
}

/* ----------------------------------------------------- */
/*            Only two loop helpers as requested         */
/* ----------------------------------------------------- */
abstract contract BatchBuilders is TokenEthSwapHelpers {

    struct EthToTokenBatch {
        bytes commands;
        bytes[] inputs;
        uint256 count;
        uint256 allocatedWeth;
        uint256 sumBips;
        uint256 directWethToSend;
    }
    /// @dev Builds the UR commands+inputs for ETH->tokens (handles direct WETH transfers here).
    function _buildEthToTokensBatch(
        MultiTokenOutput[] calldata outputs,
        address recipientAddress,
        uint32 slippageBps,
        uint256 totalEth
    ) internal returns (EthToTokenBatch memory batch) {
        address _weth = wethAddress;
        uint256 len = outputs.length;

        // Pre-allocate worst-case and write commands by index (no repeated copies).
        batch.inputs = new bytes[](len);
        batch.commands = new bytes(len);

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                address outToken = outputs[i].tokenAddress;
                if (outToken == address(0)) revert BadToken();

                uint256 weight = outputs[i].weightBips;
                batch.sumBips += weight;

                // skip zero-weight slices early
                if (weight == 0) continue;

                uint256 slice = (totalEth * weight) / HUNDRED_PERCENT_BIPS;
                if (slice == 0) continue;

                batch.allocatedWeth += slice;

                if (outToken == _weth) {
                    // Defer sending; we need WETH wrapped first.
                    batch.directWethToSend += slice;
                    continue;
                }

                (bytes1 cmd, bytes memory packed) =
                    _packWethToTokenSwap(outToken, slice, recipientAddress, slippageBps);

                batch.commands[batch.count] = cmd;
                batch.inputs[batch.count] = packed;
                ++batch.count;
            }
        }
    }

    struct TokenToEthBatch {
        bytes commands;
        bytes[] inputs;
        uint256 count;
    }

    error PreTransferInsufficient();
    /// @dev Single-pass build for tokens->ETH. Assumes tokens are unique.
    ///      Pulls each token (fee-on-transfer aware) and immediately appends a swap leg if needed.
    function _buildTokensToEthBatch(
        MultiTokenInput[] calldata inputsIn,
        uint32 slippageBps,
        bool preTransferred
    ) internal returns (TokenToEthBatch memory batch) {
        address _weth = wethAddress;
        uint256 len = inputsIn.length;

        // Pre-allocate worst case; we'll trim in _executeBatch.
        batch.inputs = new bytes[](len);
        batch.commands = new bytes(len);

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                address token = inputsIn[i].tokenAddress;
                uint256 amtIn = inputsIn[i].amount;
                if (amtIn == 0) continue;
                if (token == address(0)) revert BadToken();

                bool isWeth = (token == _weth);
                uint256 received;

                if (preTransferred) {
                    // Ensure the contract already holds the required amount
                    uint256 bal = IERC20(token).balanceOf(address(this));
                    if (bal < amtIn) revert PreTransferInsufficient();

                    if (isWeth) {
                        // No swap leg for WETH itself; we'll unwrap at the end
                        continue;
                    } else {
                        // Use the declared amount as "received"
                        received = amtIn;
                    }
                } else {
                    uint256 pulledAmount = TransferHelpers.receiveToken(token, amtIn, msg.sender);

                    if (isWeth) {
                        // Pulled WETH; no swap leg needed
                        continue;
                    } else {
                        // Pull token (fee-on-transfer aware)
                        received = pulledAmount;
                        if (received == 0) continue;
                    }
                }

                // Build packed swap leg for non-WETH tokens
                (bytes1 cmd, bytes memory packed) =
                    _packTokenToWethSwap(token, received, address(this), slippageBps);

                batch.commands[batch.count] = cmd;
                batch.inputs[batch.count] = packed;
                ++batch.count;
            }
        }
    }
}

/* ----------------------------------------------------- */
/*                        Router                          */
/* ----------------------------------------------------- */
contract MultiswapRouter is BatchBuilders, ReentrancyGuard {
    uint32 public MAX_SLIPPAGE_BIPS = 300;

    constructor(
        address _directory,
        address _v2Router,
        address _v3Factory,
        address _universalRouter,
        address _permit2
    )
        ImDirectory(_directory)
        Storage(_v2Router, _v3Factory, _universalRouter, _permit2)
    {}

    /* ────────────────────────────────────────────────────────────────
                        ETH → Multiple Tokens (WEIGHTED)
       - Wrap once
       - Build all swap legs via _buildEthToTokensBatch
       - Single Universal Router execute
    ───────────────────────────────────────────────────────────────── */
    function swapEthToMultipleTokens(
        MultiTokenOutput[] calldata outputs,
        address recipientAddress,
        uint32 slippageBps
    ) external payable nonReentrant {
        if (recipientAddress == address(0)) revert ZeroAddress();
        uint256 msgValue = msg.value;
        if (outputs.length == 0) revert InvalidInput();
        if (msgValue == 0) revert InvalidInput();
        if (slippageBps > MAX_SLIPPAGE_BIPS) revert InvalidSlippage();

        EthToTokenBatch memory batch =
            _buildEthToTokensBatch(outputs, recipientAddress, slippageBps, msgValue);

        // Validate weights after single pass
        uint256 sum = batch.sumBips;
        if (sum == 0 || sum > HUNDRED_PERCENT_BIPS) revert WeightsInvalid();

        // Wrap exactly once for all legs (including direct-WETH)
        uint256 alloc = batch.allocatedWeth;
        if (alloc > 0) TransferHelpers.wrapETH(wethAddress, alloc);

        // Execute swaps in one UR call
        _executeBatch(batch.commands, batch.inputs, batch.count);

        // Now send any direct WETH slice(s)
        uint256 direct = batch.directWethToSend;
        if (direct > 0) {
            TransferHelpers.sendToken(wethAddress, recipientAddress, direct);
        }

        // Refund any leftover ETH dust
        uint256 leftover = address(this).balance;
        if (leftover > 0) {
            TransferHelpers.sendEth(msg.sender, leftover);
        }
    }


    /* ────────────────────────────────────────────────────────────────
                        Multiple Tokens → ETH (BATCH)
       - Assume tokens are UNIQUE
       - Single-pass build via _buildTokensToEthBatchUnique
       - Single execute, then unwrap once & send
    ───────────────────────────────────────────────────────────────── */
    function swapMultipleTokensToEth(
        MultiTokenInput[] calldata inputsIn,
        address payable recipientAddress,
        uint32 slippageBps,
        bool preTransferred
    ) external nonReentrant {
        if (recipientAddress == address(0)) revert ZeroAddress();
        if (inputsIn.length == 0) revert InvalidInput();
        if (slippageBps > MAX_SLIPPAGE_BIPS) revert InvalidSlippage();

        TokenToEthBatch memory batch =
            _buildTokensToEthBatch(inputsIn, slippageBps, preTransferred);

        _executeBatch(batch.commands, batch.inputs, batch.count);

        uint256 wethBal = IERC20(wethAddress).balanceOf(address(this));
        if (wethBal == 0) revert NoSwaps();

        TransferHelpers.unwrapAndSendWETH(wethAddress,wethBal, recipientAddress);
    }

    function recoverAsset(address tokenAddress, address toAddress) external onlyOwner {
        TransferHelpers.recoverAsset(tokenAddress, toAddress);
    }

    function changeMaxSlippage(uint32 newMaxSlippageBips) external onlyOwner {
        MAX_SLIPPAGE_BIPS = newMaxSlippageBips;
    }

    receive() external payable {} // to receive ETH for wrap/unwrap only
}
