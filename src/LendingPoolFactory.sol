// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./loans16.sol";         // Import main lending contract logic
import "./ERC20Factory.sol";    // Import factory for creating LP tokens

/**
 * @title EqualFiLendingPoolFactory
 * @dev A factory contract for creating and initializing new lending pools.
 *      Each lending pool allows stablecoin deposits and borrowing against collateral.
 *      This factory handles deploying the lending pool contract and setting initial parameters.
 */
contract EqualFiLendingPoolFactory {

    // ========================== State Variables ==========================

    address[] public allPools;   // Array to store addresses of all deployed lending pools

    // ========================== Events ==========================

    /**
     * @dev Emitted when a new lending pool is created and initialized.
     * @param poolAddress The address of the newly created lending pool contract.
     * @param stablecoin The stablecoin address used in the lending pool.
     * @param collateralToken The collateral token address for securing loans.
     * @param token The token interface for lending pool operations.
     * @param factory The address of the factory used to create LP tokens.
     * @param depositTokenName The name of the deposit token for LP shares.
     * @param depositTokenSymbol The symbol of the deposit token for LP shares.
     */
    event PoolCreated(
        address indexed poolAddress,
        address stablecoin,
        address collateralToken,
        address token,
        address factory,
        string depositTokenName,
        string depositTokenSymbol
    );

    // ========================== Functions ==========================

    /**
     * @dev Creates a new lending pool and initializes it with the provided parameters.
     *      The lending pool contract is deployed, roles are set, and the pool is initialized.
     * @param stablecoin The stablecoin address for the lending pool.
     * @param collateralToken The collateral token address for securing loans in the pool.
     * @param token The token interface with burn functionality used in the lending pool.
     * @param lpFactory The address of the LP token factory contract for minting deposit tokens.
     * @param depositCapAmount The maximum amount of tokens that can be deposited in the pool.
     * @param depositTokenName The name of the LP token representing deposit shares.
     * @param depositTokenSymbol The symbol of the LP token representing deposit shares.
     * @return address The address of the newly created lending pool contract.
     */
    function createLendingPool(
        IERC20 stablecoin,
        IERC20 collateralToken,
        TokenIface token,
        EqualFiLPFactory lpFactory,
        ITokenSwap tokenSwap,
        uint256 depositCapAmount,
        string memory depositTokenName,
        string memory depositTokenSymbol
    ) external returns (address) {

        // Deploy a new instance of the EqualFiLending contract
        EqualFiLending newPool = new EqualFiLending(stablecoin, collateralToken, token, lpFactory, tokenSwap);


        /**IERC20 _stablecoin,
        IERC20 _collateralToken,
        TokenIface _token,
        EqualFiLPFactory _factory,
        ISwapRouter _swapRouter,
        address _weth9**/

        // Grant the deployer admin roles to manage the lending pool settings
        newPool.grantRole(newPool.DEFAULT_ADMIN_ROLE(), msg.sender);
        newPool.grantRole(newPool.ADMIN_ROLE(), msg.sender);
        
        // Revoke the DEFAULT_ADMIN_ROLE from this factory for security purposes
        newPool.revokeRole(newPool.DEFAULT_ADMIN_ROLE(), address(this));

        // Initialize the lending pool with deposit token name, symbol, admin, and deposit cap
        newPool.initializePool(depositTokenName, depositTokenSymbol, msg.sender, depositCapAmount);

        // Store the address of the newly deployed pool
        allPools.push(address(newPool));

        // Emit an event to log pool creation details
        emit PoolCreated(
            address(newPool),
            address(stablecoin),
            address(collateralToken),
            address(token),
            address(lpFactory),
            depositTokenName,
            depositTokenSymbol
        );

        // Return the address of the created lending pool contract
        return address(newPool);
    }
}
