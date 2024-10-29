// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title LPToken
 * @dev ERC20 token with minting and burning functionality, representing liquidity pool shares.
 *      Only accounts with specific roles (MINTER_ROLE and BURNER_ROLE) can mint and burn tokens.
 *      AccessControl from OpenZeppelin is used to manage role permissions.
 */
contract LPToken is ERC20, AccessControl {
    
    // ========================== Roles ==========================

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");   // Role identifier for minting tokens
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");   // Role identifier for burning tokens

    // ========================== Constructor ==========================

    /**
     * @dev Constructor that sets the token name and symbol, and grants roles to the deployer.
     * Grants the deployer the default admin, minter, and burner roles.
     * @param name The name of the token.
     * @param symbol The symbol of the token.
     */
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); // Assign admin role to the deployer
        _grantRole(MINTER_ROLE, msg.sender);        // Assign minter role to the deployer
        _grantRole(BURNER_ROLE, msg.sender);        // Assign burner role to the deployer
    }

    // ========================== Mint Function ==========================

    /**
     * @dev Mints tokens to a specified address. Only callable by accounts with MINTER_ROLE.
     * @param to The address to which the minted tokens will be sent.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    // ========================== Burn Function ==========================

    /**
     * @dev Burns tokens from a specified address. Only callable by accounts with BURNER_ROLE.
     * @param _from The address from which tokens will be burned.
     * @param _amount The amount of tokens to burn.
     */
    function burnFrom(address _from, uint _amount) external onlyRole(BURNER_ROLE) {
        _burn(_from, _amount);
    }
}
