// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../LiquidityPool.sol";

/**
 * @title FeeDistributor
 * @dev Library for distributing fees between admins and holders.
 */
library FeeDistributor {
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    /**
     * @dev Distributes fees between admin and holders.
     * @param pool The liquidity pool.
     * @param fee The total fee to distribute.
     */
    function distributeFees(LiquidityPool storage pool, uint256 fee) internal {
        uint256 adminFee = (fee * 50) / BASIS_POINTS_DIVISOR; // 0.50%
        uint256 holderFee = fee - adminFee;

        pool.adminFees += adminFee;
        pool.holderFees += holderFee;
    }
}
