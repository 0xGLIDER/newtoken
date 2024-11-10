// contracts/libraries/PoolUtils.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../LiquidityPool.sol";

/**
 * @title PoolUtils
 * @dev Library for utility functions related to liquidity pools.
 */
library PoolUtils {
    /**
     * @dev Calculates the total pool deposits across all underlying tokens.
     * @param tokens Array of underlying token contracts.
     * @param liquidityPools Mapping of token addresses to their respective liquidity pools.
     * @return totalDeposits The total deposits across all pools.
     */
    function getTotalPoolDeposits(IERC20Metadata[] storage tokens, mapping(address => LiquidityPool) storage liquidityPools) internal view returns (uint256 totalDeposits) {
        for (uint256 i = 0; i < tokens.length; i++) {
            LiquidityPool storage pool = liquidityPools[address(tokens[i])];
            totalDeposits += pool.totalDeposits;
        }
    }

    /**
     * @dev Retrieves the underlying token addresses.
     * @param tokens Array of underlying token contracts.
     * @return tokensList Array of underlying token addresses.
     */
    function getUnderlyingTokens(IERC20Metadata[] storage tokens) internal view returns (address[] memory tokensList) {
        tokensList = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokensList[i] = address(tokens[i]);
        }
    }
}
