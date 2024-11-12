// contracts/SuperTokenLPFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin Contracts
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./LPToken.sol";

/**
 * @title SuperTokenLPFactory
 * @dev Factory contract to deploy new instances of LPToken.
 */
contract SuperTokenLPFactory is AccessControl {

    event LPTokenCreated(address indexed lpTokenAddress, string name, string symbol);

    /**
     * @dev Constructor sets up the admin role.
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

       /**
     * @dev Deploys a new LPToken contract.
     * Grants MINTER_ROLE and BURNER_ROLE to the specified SuperToken3 contract.
     * @param name Name of the new LPToken.
     * @param symbol Symbol of the new LPToken.
     * @param superToken Address of the SuperToken3 contract to grant roles.
     * @return lpToken Address of the newly deployed LPToken.
     */
    function createLPToken(string memory name, string memory symbol, address superToken) external returns (LPToken lpToken) {
        require(superToken != address(0), "Factory: SuperToken address cannot be zero");

        lpToken = new LPToken(name, symbol);
        
        // Grant MINTER_ROLE and BURNER_ROLE to the SuperToken3 contract
        lpToken.grantRole(lpToken.MINTER_ROLE(), superToken);
        lpToken.grantRole(lpToken.BURNER_ROLE(), superToken);

        lpToken.grantRole(lpToken.DEFAULT_ADMIN_ROLE(), msg.sender);
        
        emit LPTokenCreated(address(lpToken), name, symbol);
    }

    /**
     * @dev Fallback function to reject any direct ETH transfers.
     */
    fallback() external payable {
        revert("LPFactory: Cannot accept ETH");
    }

    /**
     * @dev Receive function to reject any direct ETH transfers.
     */
    receive() external payable {
        revert("LPFactory: Cannot accept ETH");
    }
}
