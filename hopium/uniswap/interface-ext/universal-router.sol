// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}