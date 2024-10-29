// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import custom LPToken contract, which supports mint and burn functions
import "./LPToken.sol";

/**
 * @title EqualFiLPFactory
 * @dev A factory contract for creating mintable and burnable ERC20 tokens (LP Tokens) dynamically. 
 *      Tokens created by this factory can have minting and burning permissions assigned to specific addresses.
 */
contract EqualFiLPFactory {

    // ========================== Functions ==========================

    /**
     * @dev Creates a new instance of an LPToken with specified name and symbol.
     *      Grants the lending pool specified in the parameter the roles to mint and burn tokens.
     *      Assigns the DEFAULT_ADMIN_ROLE to the caller and revokes it from this factory contract.
     * @param name The name of the LP token to be created.
     * @param symbol The symbol of the LP token.
     * @param lendingpool The address of the lending pool contract to which mint and burn permissions will be granted.
     * @return LPToken A new instance of the LPToken with the specified name and symbol.
     */
    function createLPToken(string memory name, string memory symbol, address lendingpool) external returns (LPToken) {
        
        // Instantiate a new LPToken contract with the provided name and symbol
        LPToken token = new LPToken(name, symbol);

        // Grant the MINTER_ROLE to the specified lending pool, allowing it to mint tokens
        token.grantRole(token.MINTER_ROLE(), lendingpool);
        
        // Grant the BURNER_ROLE to the specified lending pool, allowing it to burn tokens
        token.grantRole(token.BURNER_ROLE(), lendingpool);

        // Transfer the DEFAULT_ADMIN_ROLE to the caller, making them the primary admin
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), msg.sender);

        // Revoke the DEFAULT_ADMIN_ROLE from this factory contract to finalize setup
        token.revokeRole(token.DEFAULT_ADMIN_ROLE(), address(this));

        // Return the newly created LPToken instance
        return token;
    }
}
