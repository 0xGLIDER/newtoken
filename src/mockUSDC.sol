// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSDC is ERC20, Ownable {
    uint8 private immutable _decimals;

    constructor(uint256 initialSupply, uint8 decimals_) ERC20("Mock USD Coin", "mUSDC") Ownable(_msgSender()) {
    _decimals = decimals_;
    _mint(msg.sender, initialSupply);
    }

    // Override decimals function to set a fixed decimals (e.g., 6 like real USDC)
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    // Function to mint new tokens (for testing purposes)
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    // Function to burn tokens (for testing purposes)
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
