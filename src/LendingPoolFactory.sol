// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./loans9.sol";
import "./ERC20Factory.sol";

contract LendingPoolFactory {
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
        ERC20Factory erc20Factory,
        string memory depositTokenName,
        string memory depositTokenSymbol
    ) external returns (address) {
        // Deploy the new lending pool contract
        MergedStablecoinLending newPool = new MergedStablecoinLending(stablecoin, collateralToken, token, erc20Factory);

        // Initialize the pool and create the ERC20 token for deposit shares
        newPool.initializePool(depositTokenName, depositTokenSymbol);

        // Store the address of the deployed pool
        allPools.push(address(newPool));

        // Emit an event
        emit PoolCreated(
            address(newPool),
            address(stablecoin),
            address(collateralToken),
            address(token),
            address(erc20Factory),
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
