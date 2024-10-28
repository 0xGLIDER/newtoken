// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./loans15.sol";
import "./ERC20Factory.sol";

contract EqualFiLendingPoolFactory {
    address[] public allPools;
    event PoolCreated(
        address indexed poolAddress,
        address stablecoin,
        address collateralToken,
        address token,
        address factory,
        string depositTokenName,
        string depositTokenSymbol
    );

    // Function to create a new lending pool and initialize it
    function createLendingPool(
        IERC20 stablecoin,
        IERC20 collateralToken,
        TokenIface token,
        EqualFiLPFactory lpFactory,
        uint256 depositCapAmount,
        string memory depositTokenName,
        string memory depositTokenSymbol
    ) external returns (address) {
        // Deploy the new lending pool contract
        EqualFiLending newPool = new EqualFiLending(stablecoin, collateralToken, token, lpFactory);

        newPool.grantRole(newPool.DEFAULT_ADMIN_ROLE(), msg.sender);
        newPool.grantRole(newPool.ADMIN_ROLE(), msg.sender);
        newPool.revokeRole(newPool.DEFAULT_ADMIN_ROLE(), address(this));
        


        // Initialize the pool and create the ERC20 token for deposit shares
        newPool.initializePool(depositTokenName, depositTokenSymbol, msg.sender, depositCapAmount);

        // Store the address of the deployed pool
        allPools.push(address(newPool));

        // Emit an event
        emit PoolCreated(
            address(newPool),
            address(stablecoin),
            address(collateralToken),
            address(token),
            address(lpFactory),
            depositTokenName,
            depositTokenSymbol
        );

        return address(newPool);
    }

    // Function to get all deployed lending pools
    function getAllPools() external view returns (address[] memory) {
        return allPools;
    }

}
