// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./LPToken.sol";  // Import your custom ERC20 token

// Factory for creating mintable and burnable ERC20 tokens dynamically
contract EqualFiLPFactory {
    function createLPToken(string memory name, string memory symbol, address lendingpool) external returns (LPToken) {
        // Create and return a new instance of the ERC20 token with minting and burning functionality
        LPToken token = new LPToken(name, symbol);

        // Grant the MINTER_ROLE to the lending pool
        token.grantRole(token.MINTER_ROLE(), lendingpool);
        token.grantRole(token.BURNER_ROLE(), lendingpool);

        // Transfer the DEFAULT_ADMIN_ROLE to the owner's wallet (or pool deployer)
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), msg.sender);

        // Revoke the DEFAULT_ADMIN_ROLE from the factory contract
        token.revokeRole(token.DEFAULT_ADMIN_ROLE(), address(this));

        return token;
    }
}





