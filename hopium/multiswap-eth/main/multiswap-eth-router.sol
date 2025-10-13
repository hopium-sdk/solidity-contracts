// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* ----------------------------------------------------- */
/*                External interfaces (deps)             */
/* ----------------------------------------------------- */
import "hopium/common/interface/imDirectory.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "hopium/common/interface/ierc20.sol";
import "hopium/common/interface/iweth.sol";
import "hopium/multiswap-eth/interface/uniswapV2.sol";
import "hopium/multiswap-eth/interface/uniswapV3.sol";
import "hopium/multiswap-eth/interface/universal-router.sol";
import "hopium/common/utils/transfer-helpers.sol";
import "hopium/common/storage/bips.sol";
import "hopium/multiswap-eth/interface/iMultiSwapEthRouter.sol";
import "hopium/common/interface/imPermit2.sol";
/* ----------------------------------------------------- */
/*                  Custom errors (cheaper)              */
/* ----------------------------------------------------- */
error ZeroAddress();
error EmptyArray();
error WeightsInvalid();
error NoPoolFound();

/* ----------------------------------------------------- */
/*                        Storage                        */
/* ----------------------------------------------------- */
abstract contract Storage {
    address public immutable wethAddress;

    IPermit2 public immutable permit2; 

    IUniswapV2Factory public immutable v2Factory;
    IUniswapV3Factory public immutable v3Factory;

    IUniswapV2Router02 public immutable v2Router;   // read-only getAmountsOut
    IUniswapV3Quoter    public immutable v3Quoter;  // quoteExactInputSingle
    IUniversalRouter    public immutable uRouter;   // actual swaps

    constructor(
        address _v2Router,
        address _v3Factory,
        address _v3Quoter,
        address _universalRouter,
        address _permit2
    ) {
        if (_v3Factory == address(0)) revert ZeroAddress();
        if (_v2Router  == address(0)) revert ZeroAddress();
        if (_v3Quoter  == address(0)) revert ZeroAddress();
        if (_universalRouter == address(0)) revert ZeroAddress();

        v3Factory = IUniswapV3Factory(_v3Factory);
        v2Router  = IUniswapV2Router02(_v2Router);
        v3Quoter  = IUniswapV3Quoter(_v3Quoter);
        uRouter   = IUniversalRouter(_universalRouter);

        address _weth = IUniswapV2Router02(_v2Router).WETH();
        wethAddress = _weth;
        v2Factory   = IUniswapV2Factory(IUniswapV2Router02(_v2Router).factory());

        permit2 = IPermit2(_permit2);
    }
}

/* ----------------------------------------------------- */
/*                     Pool discovery                    */
/* ----------------------------------------------------- */
abstract contract PoolFinder is Storage, ImDirectory {
    error TokenIsWETH();

    mapping(address => Pool) public cachedPools;

    // constant fee tiers — cheapest way (no constructor needed)
    uint24 internal constant V3_FEE0 = 3000;   // 0.3%
    uint24 internal constant V3_FEE1 = 10000;  // 1%
    uint256 internal constant V3_FEE_COUNT = 2;

    uint256 public staleTime = 6 hours;

    // ---- internal pool finder (pure read logic)
    function _findBestWethPool(address tokenAddress) internal view returns (Pool memory pool) {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (tokenAddress == wethAddress) revert TokenIsWETH();

        address _weth = wethAddress;
        IERC20 Weth = IERC20(_weth);
        uint256 poolWethLiquidity;

        // --- Uniswap V2 ---
        address v2Pair = v2Factory.getPair(tokenAddress, _weth);
        if (v2Pair != address(0)) {
            (uint112 r0, uint112 r1, ) = IUniswapV2Pair(v2Pair).getReserves();
            address t0 = IUniswapV2Pair(v2Pair).token0();
            uint256 w = (t0 == _weth) ? uint256(r0) : uint256(r1);
            if (w > poolWethLiquidity) {
                pool.isV3Pool = 0;
                pool.poolAddress = v2Pair;
                pool.poolFee = 0;
                poolWethLiquidity = w;
            }
        }

        // --- Uniswap V3 --- (iterate with unchecked)
        for (uint256 i; i < V3_FEE_COUNT; ) {
            // emulate constant array indexing
            uint24 fee = (i == 0) ? V3_FEE0 : V3_FEE1;

            address p = v3Factory.getPool(tokenAddress, _weth, fee);
            if (p != address(0)) {
                uint256 w = Weth.balanceOf(p);
                if (w > poolWethLiquidity) {
                    pool.isV3Pool = 1;
                    pool.poolAddress = p;
                    pool.poolFee = fee;
                    poolWethLiquidity = w;
                }
            }
            unchecked { ++i; }
        }

        pool.lastCached = uint64(block.timestamp);
    }

    // ---- READ fn: hit -> return cache; miss -> compute (no writes)
    function getBestWethPool(address tokenAddress) external view returns (Pool memory pool) {
        pool = cachedPools[tokenAddress];
        if (pool.poolAddress != address(0)) return pool;
        return _findBestWethPool(tokenAddress);
    }

    // ---- WRITE fn: populate if missing; refresh only when stale; else return cached
    function getBestWethPoolUpdatable(address tokenAddress) public returns (Pool memory out) {
        Pool storage slot = cachedPools[tokenAddress];

        // missing?
        if (slot.poolAddress == address(0)) {
            out = _findBestWethPool(tokenAddress);
            cachedPools[tokenAddress] = out; // <-- fix
            return out;
        }

        // stale?
        if (block.timestamp - slot.lastCached > staleTime) {
            Pool memory fresh = _findBestWethPool(tokenAddress);
            if (fresh.poolAddress != slot.poolAddress) {
                cachedPools[tokenAddress] = fresh; // <-- fix
                return fresh;
            } else {
                slot.lastCached = uint64(block.timestamp); // ok to update a single field
            }
        }

        // fresh cache
        out = slot;
    }

    function setStaleTimePoolCache(uint256 newStaleTime) external onlyOwner {
        staleTime = newStaleTime;
    }
}

/* ----------------------------------------------------- */
/*                      Quote helpers                    */
/* ----------------------------------------------------- */
error QuoteUnavailable();
abstract contract QuoteHelpers is PoolFinder, TransferHelpers {
    function _applySlippage(uint256 quoteOut, uint32 slippageBps) internal pure returns (uint256) {
        if (slippageBps > HUNDRED_PERCENT_BIPS) revert WeightsInvalid();
        return (quoteOut * (HUNDRED_PERCENT_BIPS - slippageBps)) / HUNDRED_PERCENT_BIPS;
    }

    /// @dev V2 minOut calc using Router.getAmountsOut (read-only use)
    function _calcMinOutV2(
        address /*tokenInAddress*/,
        address /*tokenOutAddress*/,
        uint256 /*amountIn*/,
        uint32  /*slippageBps*/
    ) internal pure returns (uint256 minOut) {
        // Re-enable to use real quotes; zero for now.
        minOut = 0;
    }

    /// @dev V3 minOut calc using Quoter.quoteExactInputSingle (non-view)
    function _calcMinOutV3(
        address /*tokenInAddress*/,
        address /*tokenOutAddress*/,
        uint24  /*fee*/,
        uint256 /*amountIn*/,
        uint32  /*slippageBps*/
    ) internal pure returns (uint256 minOut) {
        // Re-enable to use real quotes; zero for now.
        minOut = 0;
    }
}

/* ----------------------------------------------------- */
/*                 Universal Router swapper              */
/* ----------------------------------------------------- */
abstract contract URSwapHelpers is QuoteHelpers, ImPermit2 {
    // Command bytes (from Uniswap’s Commands.sol)
    uint256 constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint256 constant CMD_V2_SWAP_EXACT_IN = 0x08;

    /* --------- ETH <-> WETH handled in this contract only --------- */
    function _wrapETH(uint256 amt) internal {
        if (address(this).balance < amt) revert InsufficientETH();
        IWETH(wethAddress).deposit{value: amt}();
    }

    error ETHSendFailure();
    function _unwrapAndSendWETH(uint256 amt, address payable to) internal {
        IWETH(wethAddress).withdraw(amt);
        (bool ok, ) = to.call{value: amt}("");
        if (!ok) revert ETHSendFailure();
    }

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
        _approveMaxIfNeeded(tokenInAddress, address(permit2), amountIn);
        _approveMaxIfNeededPermit2(address(permit2), tokenInAddress, address(uRouter), uint160(amountIn));
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
        _approveMaxIfNeeded(tokenInAddress, address(permit2), amountIn);
        _approveMaxIfNeededPermit2(address(permit2), tokenInAddress, address(uRouter), uint160(amountIn));
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
abstract contract TokenEthSwapHelpers is URSwapHelpers {
    /// @notice Build a WETH->token swap leg (no execute).
    function _packWethToTokenSwap(
        address tokenAddress,
        uint256 wethAmount,
        address recipientAddress,
        uint32 slippageBps
    ) internal returns (bytes1 cmd, bytes memory packedInput) {
        if (wethAmount == 0) return (bytes1(0), bytes(""));
         Pool memory pool = getBestWethPoolUpdatable(tokenAddress);
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

        Pool memory pool = getBestWethPoolUpdatable(tokenAddress);
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
                    uint256 pulledAmount = _receiveToken(token, amtIn, msg.sender);

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
contract MultiswapEthRouter is BatchBuilders, ReentrancyGuard {
    constructor(
        address _directory,
        address _v2Router,
        address _v3Factory,
        address _v3Quoter,
        address _universalRouter,
        address _permit2
    )
        ImDirectory(_directory)
        Storage(_v2Router, _v3Factory, _v3Quoter, _universalRouter, _permit2)
    {}

    /* ────────────────────────────────────────────────────────────────
                        ETH → Multiple Tokens (WEIGHTED)
       - Wrap once
       - Build all swap legs via _buildEthToTokensBatch
       - Single Universal Router execute
    ───────────────────────────────────────────────────────────────── */
    error NoEthSent();

    function swapEthToMultipleTokens(
        MultiTokenOutput[] calldata outputs,
        address recipientAddress,
        uint32 slippageBps
    ) external payable nonReentrant {
        if (recipientAddress == address(0)) revert ZeroAddress();
        uint256 msgValue = msg.value;
        if (outputs.length == 0) revert EmptyArray();
        if (msgValue == 0) revert NoEthSent();

        EthToTokenBatch memory batch =
            _buildEthToTokensBatch(outputs, recipientAddress, slippageBps, msgValue);

        // Validate weights after single pass
        uint256 sum = batch.sumBips;
        if (sum == 0 || sum > HUNDRED_PERCENT_BIPS) revert WeightsInvalid();

        // Wrap exactly once for all legs (including direct-WETH)
        uint256 alloc = batch.allocatedWeth;
        if (alloc > 0) _wrapETH(alloc);

        // Execute swaps in one UR call
        _executeBatch(batch.commands, batch.inputs, batch.count);

        // Now send any direct WETH slice(s)
        uint256 direct = batch.directWethToSend;
        if (direct > 0) {
            _sendToken(wethAddress, recipientAddress, direct);
        }

        // Refund any leftover ETH dust
        uint256 leftover = address(this).balance;
        if (leftover > 0) {
            _sendEth(msg.sender, leftover);
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
        if (inputsIn.length == 0) revert EmptyArray();

        TokenToEthBatch memory batch =
            _buildTokensToEthBatch(inputsIn, slippageBps, preTransferred);

        _executeBatch(batch.commands, batch.inputs, batch.count);

        uint256 wethBal = IERC20(wethAddress).balanceOf(address(this));
        if (wethBal == 0) revert NoSwaps();

        _unwrapAndSendWETH(wethBal, recipientAddress);
    }

    function recoverAsset(address tokenAddress, address toAddress) public onlyOwner {
        _recoverAsset(tokenAddress, toAddress);
    }

    receive() external payable {} // to receive ETH for wrap/unwrap only
}
