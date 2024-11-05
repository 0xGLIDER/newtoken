// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title Types
 * @dev Defines shared structs used across the contract and libraries.
 */

struct LoanTerms {
    uint256 durationInBlocks;
    uint256 apyBps;
}
