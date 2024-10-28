// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

// A basic ERC20 token with minting and burning functionality. Used to track depositors shares of Liquidity.
contract LPToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); // Assign admin role to the deployer
        _grantRole(MINTER_ROLE, msg.sender); // Assign minter role to the deployer
        _grantRole(BURNER_ROLE, msg.sender);
    }

    function burnFrom(address _from, uint _amount) external onlyRole(BURNER_ROLE) {
        _burn(_from, _amount);
    }

    // Only accounts with the MINTER_ROLE can mint tokens
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
}
