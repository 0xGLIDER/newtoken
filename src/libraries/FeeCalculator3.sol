// contracts/libraries/FeeCalculator2.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Types.sol";

library FeeCalculator2 {
    /**
     * @dev Calculates the time-based fee for a loan.
     * @param amount The principal amount of the loan.
     * @param borrowBlock The block number when the loan was taken.
     * @param currentBlock The current block number.
     * @param blocksInYear Total number of blocks in a year.
     * @param minimumFeeBps The minimum fee in basis points.
     * @param basisPointsDivisor The divisor for basis points calculations.
     * @param apyBps The specific APY for this loan.
     * @return fee The calculated fee.
     */
    function calculateTimeBasedFee(
        uint256 amount,
        uint256 borrowBlock,
        uint256 currentBlock,
        uint256 blocksInYear,
        uint256 minimumFeeBps,
        uint256 basisPointsDivisor,
        uint256 apyBps
    ) internal pure returns (uint256 fee) {
        uint256 blocksElapsed = currentBlock > borrowBlock ? currentBlock - borrowBlock : 0;
        uint256 feeBps = (apyBps * blocksElapsed) / blocksInYear;
        if (feeBps < minimumFeeBps) {
            feeBps = minimumFeeBps;
        }
        fee = (amount * feeBps) / basisPointsDivisor;
    }
}
