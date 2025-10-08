// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";
import "hopium/etf/interface/imEtfRouter.sol";
import "hopium/etf/interface/imEtfTokenEvents.sol";

/// @notice Minimal ERC20 Etf Token
contract EtfToken is ERC20, ImEtfRouter, ImEtfTokenEvents {

    constructor(string memory name_, string memory symbol_, address _directory) ERC20(name_, symbol_) ImDirectory(_directory) {}

    function mint(address to, uint256 amount) external onlyEtfRouter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyEtfRouter {
        _burn(from, amount);
    }

    /// @dev OZ v5.4 central hook for transfer/mint/burn.
    /// We forward a transfer event to the EtfTokenEvents contract.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value); // state updated and standard Transfer emitted

        IEtfTokenEvents etfTokenEvents = getEtfTokenEvents();
        require(address(etfTokenEvents) != address(0), "Etf token events contract not set");

        etfTokenEvents.emitTransferEvent(from, to, value);
    }
}

/// @notice Factory that deploys ERC20 Contract for each etf
contract EtfTokenDeployer is ImDirectory, ImEtfFactory {

    event EtfTokenDeployed(
        uint256 indexed indexId,
        address etfTokenAddress,
        string name,
        string symbol
    );

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Deploys a new ERC20 etf token and returns its address
    function deployEtfToken(uint256 indexId, string calldata name, string calldata symbol) external onlyEtfFactory returns (address) {
        EtfToken newToken = new EtfToken(name, symbol, address(Directory));
        address etfTokenAddress = address(newToken);

        emit EtfTokenDeployed(indexId, etfTokenAddress, name, symbol);

        return etfTokenAddress;
    }
}
