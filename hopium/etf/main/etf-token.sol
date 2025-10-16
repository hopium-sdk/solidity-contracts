// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfRouter.sol";
import "hopium/etf/interface/imEtfTokenEvents.sol";

/// @notice Cloneable ETF ERC20 with per-clone name/symbol via initialize()
/// @dev Uses OZ *Upgradeable* ERC20 so name/symbol can be set at runtime.
///      Access control (onlyEtfRouter/onlyOwner) resolves via ImDirectory.
contract EtfToken is Initializable, ERC20Upgradeable, ImEtfRouter, ImEtfTokenEvents {
    bool private _initialized;
    uint256 public etfId;

    /// @dev The logic/implementation constructor runs once when you deploy the master.
    ///      Clones DO NOT run constructors, they use initialize().
    constructor(address _directory) ImDirectory(_directory) {
        // Prevent the implementation from being used directly post-deployment.
        // (No state to lock here; modifiers rely on Directory anyway.)
    }

    error AlreadyInitialized();
    /// @notice One-time initializer for clones (constructors don't run for proxies)
    function initialize(uint256 etfId_, string memory name_, string memory symbol_, address directory_) external initializer {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        // Wire Directory for this clone first (so modifiers work)
        _setDirectory(directory_);

        // Initialize ERC20 storage (name/symbol)
        __ERC20_init(name_, symbol_);

        etfId = etfId_;
    }

    /// @notice Router-controlled mint
    function mint(address to, uint256 amount) external onlyEtfRouter {
        _mint(to, amount);
    }

    /// @notice Router-controlled burn
    function burn(address from, uint256 amount) external onlyEtfRouter {
        _burn(from, amount);
    }

    /// @dev OZ v5 central hook for transfer/mint/burn; forward event to EtfTokenEvents
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value); // state + standard Transfer event

        IEtfTokenEvents etfTokenEvents = getEtfTokenEvents();
        require(address(etfTokenEvents) != address(0), "EtfToken: events contract not set");
        etfTokenEvents.emitTransferEvent(etfId, from, to, value);
    }
}
