// contracts/interfaces/IFlashLoanReceiver.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IFlashLoanReceiver
 * @dev Interface that flash loan receivers must implement.
 */
interface IFlashLoanReceiver2 {
  
    function executeOperation(
        address tokenAddress,
        uint256 amount,
        uint256 fee,
        address receiver,
        bytes calldata params
    ) external;
}
