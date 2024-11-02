
// contracts/interfaces/IEqualToken.sol
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
/**
 * @title iface
 * @dev Interface for ERC20 token interactions including balance checks, minting, and burning.
 */
interface IEqualFiToken is IERC20{
    /**
     * @dev Returns the ERC20 token balance of a specific account.
     * @param account The address to query the balance of.
     * @return The token balance of the specified account.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Mints a specified amount of tokens to a recipient.
     * @param recipient The address to receive the minted tokens.
     * @param amount The number of tokens to mint.
     */
    function mintTo(address recipient, uint256 amount) external;

    /**
     * @dev Burns a specified amount of tokens from a sender's account.
     * @param sender The address from which tokens will be burned.
     * @param amount The number of tokens to burn.
     */
    function burnFrom(address sender, uint256 amount) external;
}