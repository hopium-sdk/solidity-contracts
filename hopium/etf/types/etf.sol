// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

struct Asset {
    address tokenAddress;
    uint16 weightBips;
}

struct Etf {
    string name;
    string ticker;
    Asset[] assets;
}
