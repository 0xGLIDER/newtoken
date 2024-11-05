// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Types.sol";

/**
 * @title FeeCalculator
 * @dev Library for calculating fees based on loan terms.
 */
library FeeCalculator {
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    /**
     * @dev Calculates the fee based on the amount and loan terms.
     * @param amount The amount borrowed.
     * @param terms The loan terms.
     * @param blocksInYear The number of blocks in a year.
     * @param minimumFeeBps The minimum fee in basis points.
     * @return fee The calculated fee.
     */
    function calculateFee(
        uint256 amount,
        LoanTerms memory terms,
        uint256 blocksInYear,
        uint256 minimumFeeBps
    ) internal pure returns (uint256 fee) {
        fee = (amount * terms.apyBps * terms.durationInBlocks) / (BASIS_POINTS_DIVISOR * blocksInYear);
        uint256 minimumFee = (amount * minimumFeeBps) / BASIS_POINTS_DIVISOR;
        return fee > minimumFee ? fee : minimumFee;
    }
}
