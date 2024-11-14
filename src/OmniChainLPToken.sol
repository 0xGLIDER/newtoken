// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";

/**
 * @title LPToken
 * @dev ERC20 token with minting and burning functionality, representing liquidity pool shares.
 *      Only accounts with specific roles (MINTER_ROLE and BURNER_ROLE) can mint and burn tokens.
 *      AccessControl from OpenZeppelin is used to manage role permissions.
 */
contract LPToken is OFT, AccessControl {
    
    // ========================== Roles ==========================

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");   // Role identifier for minting tokens
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");   // Role identifier for burning tokens

    // ========================== Constructor ==========================

    constructor(
        string memory _name, 
        string memory _symbol, 
        address _lzEndpoint, 
        address _delegate) OFT(_name, _symbol, _lzEndpoint, _delegate) Ownable(_delegate) {
        
        
        _grantRole(DEFAULT_ADMIN_ROLE, _delegate); // Assign admin role to the deployer
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
