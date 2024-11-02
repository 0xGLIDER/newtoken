// contracts/interfaces/IFlashLoanReceiver.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IFlashLoanReceiver
 * @dev Interface that flash loan receivers must implement.
 */
interface IFlashLoanReceiver {
    /**
     * @dev Executes an operation after receiving the flash loan.
     * @param amount The amount of tokens borrowed.
     * @param fee The fee to be paid for the flash loan.
     * @param params Arbitrary data passed from the flash loan initiator.
     */
    function executeOperation(
        uint256 amount,
        uint256 fee,
        bytes calldata params
    ) external;
}
