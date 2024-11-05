// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title LiquidityPool
 * @dev Defines the structure of a liquidity pool.
 */
struct LiquidityPool {
    IERC20Metadata token;
    uint256 totalDeposits;
    uint256 totalBorrowed;
    uint256 totalFees;
    uint256 adminFees;
    uint256 holderFees;
}
