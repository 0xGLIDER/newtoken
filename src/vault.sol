// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Vault is AccessControl {

    // Define a role identifier for the admin who can transfer funds
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Events for transfer actions
    event EthTransferred(address indexed to, uint256 amount);
    event ERC20Transferred(address indexed token, address indexed to, uint256 amount);

    // Constructor to set the deployer as the default admin
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender()); // Grant the default admin role
        _grantRole(ADMIN_ROLE, _msgSender()); // Grant the admin role
    }

    // Function to check the ETH balance of the contract
    function checkEthBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // Function to check the balance of an ERC20 token held by the contract
    function checkERC20Balance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // Function to transfer ETH from the vault
    function transferEth(address payable to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(address(this).balance >= amount, "Vault: insufficient ETH balance");
        to.transfer(amount);
        emit EthTransferred(to, amount);
    }

    // Function to transfer ERC20 tokens from the vault
    function transferERC20(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(IERC20(token).balanceOf(address(this)) >= amount, "Vault: insufficient ERC20 token balance");
        IERC20(token).transfer(to, amount);
        emit ERC20Transferred(token, to, amount);
    }

    // Fallback function to accept ETH payments
    receive() external payable {}
}
