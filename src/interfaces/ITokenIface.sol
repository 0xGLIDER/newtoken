// contracts/interfaces/ITokenIface.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title TokenIface
 * @dev Interface extending IERC20Metadata with a burnFrom function.
 */
interface TokenIface is IERC20Metadata {
    /**
     * @dev Burns a specific amount of tokens from a user.
     * @param user The address from which tokens will be burned.
     * @param amount The amount of tokens to burn.
     */
    function burnFrom(address user, uint256 amount) external;
}
