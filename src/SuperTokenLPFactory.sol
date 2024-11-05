// contracts/ERC20Factory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin Contracts
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./LPToken.sol";

/**
 * @title ERC20Factory
 * @dev Factory contract to deploy new instances of LPToken.
 */
contract SuperTokenLPFactory is AccessControl {
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");

    event LPTokenCreated(address indexed lpTokenAddress, string name, string symbol);

    /**
     * @dev Constructor sets up the admin role.
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);//NEED TO GRANT SUPERTOKENFACTORY DEFAULT ADMIN SOMEHOW
    }

    /**
     * @dev Deploys a new LPToken contract.
     * Grants the caller the MINTER_ROLE and BURNER_ROLE on the new LPToken.
     * @param name Name of the new LPToken.
     * @param symbol Symbol of the new LPToken.
     * @return lpToken Address of the newly deployed LPToken.
     */
    function createLPToken(string memory name, string memory symbol, address superToken) external returns (LPToken lpToken) {
        lpToken = new LPToken(name, symbol);
        
        // Grant MINTER_ROLE and BURNER_ROLE to the caller (usually the SuperToken2 contract)
        lpToken.grantRole(lpToken.MINTER_ROLE(), superToken);
        lpToken.grantRole(lpToken.BURNER_ROLE(), superToken);
        
        emit LPTokenCreated(address(lpToken), name, symbol);
    }
}

 /**function createLPToken(string memory name, string memory symbol, address lendingpool) external returns (LPToken) {
        
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
    }**/