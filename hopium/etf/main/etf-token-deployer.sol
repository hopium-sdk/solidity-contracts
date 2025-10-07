// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "hopium/common/interface/imDirectory.sol";
import "hopium/etf/interface/imEtfFactory.sol";

/// @notice Minimal ERC20 Etf Token
contract EtfToken is ERC20, ImEtfFactory {

    constructor(string memory name_, string memory symbol_, address _directory) ERC20(name_, symbol_) ImDirectory(_directory) {}

    function mint(address to, uint256 amount) external onlyEtfFactory {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyEtfFactory {
        _burn(from, amount);
    }
}

/// @notice Factory that deploys ERC20 Contract for each etf
contract EtfTokenDeployer is ImDirectory, ImEtfFactory {

    event EtfTokenDeployed(
        uint256 indexed indexId,
        address tokenAddress,
        string name,
        string symbol
    );

    constructor(address _directory) ImDirectory(_directory) {}

    /// @notice Deploys a new ERC20 index token and returns its address
    function deployEtfToken(uint256 indexId, string calldata name, string calldata symbol) external onlyEtfFactory returns (address) {
        EtfToken newToken = new EtfToken(name, symbol, address(Directory));
        address tokenAddress = address(newToken);

        emit EtfTokenDeployed(indexId, tokenAddress, name, symbol);

        return tokenAddress;
    }
}
