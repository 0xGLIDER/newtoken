// contracts/interfaces/ITokenSwap.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ITokenSwap
 * @dev Interface for the TokenSwap contract.
 */
interface ITokenSwap {
    /**
     * @dev Swaps a specified amount of inputToken to USDC.
     * @param inputToken The address of the token to swap from.
     * @param amountIn The amount of inputToken to swap.
     * @param amountOutMinimum The minimum amount of USDC to receive.
     * @param deadline The timestamp after which the swap is invalid.
     * @return amountOut The amount of USDC received from the swap.
     */
    function swapToUSDC(
        address inputToken,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external returns (uint256 amountOut);
}
