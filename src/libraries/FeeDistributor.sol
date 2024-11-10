// contracts/libraries/FeeDistributor.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../LiquidityPool.sol";

/**
 * @title FeeDistributor
 * @dev Library for distributing fees within a liquidity pool.
 */
library FeeDistributor {
    /**
     * @dev Distributes the fee within the liquidity pool.
     *      Example: 10% to adminFees and 90% to holderFees.
     * @param pool The liquidity pool.
     * @param fee The fee amount to distribute.
     */
    function distributeFees(LiquidityPool storage pool, uint256 fee) internal {
        uint256 adminFee = (fee * 1000) / 10000; // 10% to admin
        uint256 holderFee = fee - adminFee;      // 90% to holders

        pool.adminFees += adminFee;
        pool.holderFees += holderFee;

        emit FeesDistributed(adminFee, holderFee);
    }

    /**
     * @dev Emitted when fees are distributed.
     * @param adminFee The amount of fee allocated to the admin.
     * @param holderFee The amount of fee allocated to holders.
     */
    event FeesDistributed(uint256 adminFee, uint256 holderFee);
}
