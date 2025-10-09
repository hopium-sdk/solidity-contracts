// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "hopium/common/interface/imDirectory.sol";

abstract contract ImActive is ImDirectory {
    bool public isActive = true;

    modifier onlyActive() {
        require(isActive, "Contract is not active");
        _;
    }

    function setActive(bool _active) public onlyOwner {
        isActive = _active;
    }
}