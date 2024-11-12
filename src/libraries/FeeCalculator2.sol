// libraries/FeeCalculator2.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import the Types.sol to access LoanTerms
import "../Types2.sol";

/**
 * @title FeeCalculator2
 * @dev Library for calculating time-based fees for loans.
 */
library FeeCalculator2 {
    /**
     * @dev Calculates a time-based fee.
     * @param terms The loan terms including duration and APY.
     * @param amount The principal loan amount.
     * @param borrowBlock The block number when the loan was taken.
     * @param currentBlock The current block number.
     * @param blocksInYear The total number of blocks in a year.
     * @param minimumFeeBps The minimum fee in basis points.
     * @param basisPointsDivisor The divisor for basis points calculations.
     * @return fee The calculated fee.
     */
    function calculateTimeBasedFee(
        LoanTerms memory terms,
        uint256 amount,
        uint256 borrowBlock,
        uint256 currentBlock,
        uint256 blocksInYear,
        uint256 minimumFeeBps,
        uint256 basisPointsDivisor
    ) internal pure returns (uint256 fee) {
        require(currentBlock >= borrowBlock, "FeeCalculator2: current block is before borrow block");
        
        uint256 blocksElapsed = currentBlock - borrowBlock;
        
        if (blocksElapsed > terms.durationInBlocks) {
            blocksElapsed = terms.durationInBlocks;
        }

        // Calculate proportional fee
        fee = (amount * terms.apyBps * blocksElapsed) / (basisPointsDivisor * blocksInYear);

        // Ensure fee is at least the minimum fee
        uint256 minimumFee = (amount * minimumFeeBps) / basisPointsDivisor;
        if (fee < minimumFee) {
            fee = minimumFee;
        }
    }
}
