// contracts/libraries/FeeCalculator3.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title FeeCalculator3
 * @dev Library for calculating time-based fees for loans.
 */
library FeeCalculator3 {
    /**
     * @dev Calculates the time-based fee for a loan.
     * @param amount The principal amount borrowed.
     * @param blocksElapsed The number of blocks elapsed since the loan was taken.
     * @param blocksInYear The total number of blocks in a year.
     * @param minimumFeeBps The minimum fee in basis points.
     * @param basisPointsDivisor The divisor for basis points calculations.
     * @param apyBps The annual percentage yield in basis points.
     * @return fee The calculated fee.
     */
    function calculateTimeBasedFee(
        uint256 amount,
        uint256 blocksElapsed,
        uint256 blocksInYear,
        uint256 minimumFeeBps,
        uint256 basisPointsDivisor,
        uint256 apyBps
    ) internal pure returns (uint256 fee) {
        require(blocksElapsed >= 0, "FeeCalculator3: blocksElapsed cannot be negative");

        // Calculate the proportional fee based on blocks elapsed and APY
        fee = (amount * apyBps * blocksElapsed) / (blocksInYear * basisPointsDivisor);
        
        // Ensure the fee is at least the minimum fee
        uint256 minimumFee = (amount * minimumFeeBps) / basisPointsDivisor;
        if (fee < minimumFee) {
            fee = minimumFee;
        }
    }
}
