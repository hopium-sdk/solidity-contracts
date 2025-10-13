// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3Quoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96; // 0 for no limit
    }

    /// @return amountOut, sqrtPriceX96After, initializedTicksCrossed, gasEstimate
    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        returns (uint256, uint160, uint32, uint256);
}