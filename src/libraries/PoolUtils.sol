// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../LiquidityPool.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title PoolUtils
 * @dev Library for utility functions related to liquidity pools.
 */
library PoolUtils {
    /**
     * @dev Calculates the total deposits across all pools.
     * @param tokens The array of underlying token contracts.
     * @param pools The mapping of liquidity pools.
     * @return total The total deposits.
     */
    function getTotalPoolDeposits(
        IERC20Metadata[] memory tokens,
        mapping(address => LiquidityPool) storage pools
    ) internal view returns (uint256 total) {
        for (uint256 i = 0; i < tokens.length; i++) {
            total += pools[address(tokens[i])].totalDeposits;
        }
    }

    /**
     * @dev Retrieves the underlying token addresses.
     * @param tokens The array of underlying token contracts.
     * @return addresses The array of token addresses.
     */
    function getUnderlyingTokens(IERC20Metadata[] memory tokens) internal pure returns (address[] memory addresses) {
        addresses = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            addresses[i] = address(tokens[i]);
        }
    }
}
