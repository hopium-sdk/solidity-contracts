// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

struct Holding {
    address tokenAddress;
    uint16 weightBips;
}

struct Index {
    string name;
    string ticker;
    Holding[] holdings;
}
