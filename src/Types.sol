// contracts/libraries/Types.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Types {
    struct LoanTerms {
        uint256 durationInBlocks;
        uint256 apyBps; // For depositors
        uint256 apyBpsNonDepositor; // For non-depositors
    }
}