// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

struct Pool {
    address poolAddress; // 20
    uint24  poolFee;     // 3
    uint8   isV3Pool;    // 1 (0/1)
    uint64  lastCached;  // 8
}