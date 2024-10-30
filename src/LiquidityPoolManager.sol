// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract UniswapV3LiquidityManager is Ownable {
    uint24 public fee;  // Pool fee (e.g., 3000 for 0.3%)
    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory public factory;

    constructor(
        uint24 _fee,
        address _positionManager,
        address _factory
    ) {
        fee = _fee;
        positionManager = INonfungiblePositionManager(_positionManager);
        factory = IUniswapV3Factory(_factory);
    }

    /// @notice Approve tokens for the Uniswap position manager
    function approveTokens(address tokenA, address tokenB, uint256 amountA, uint256 amountB) external onlyOwner {
        IERC20(tokenA).approve(address(positionManager), amountA);
        IERC20(tokenB).approve(address(positionManager), amountB);
    }

    /// @notice Create the Uniswap V3 pool for the specified token pair if it doesn’t exist, then return its address
    function createPool(address tokenA, address tokenB, uint160 sqrtPriceX96) external onlyOwner returns (address pool) {
        require(factory.getPool(tokenA, tokenB, fee) == address(0), "Pool already exists");
        pool = factory.createPool(tokenA, tokenB, fee);
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);  // Initialize with sqrtPriceX96
    }

    /// @notice Adds liquidity to the specified pool, creating a new position NFT
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        int24 tickLower,
        int24 tickUpper
    ) external onlyOwner returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        require(IERC20(tokenA).balanceOf(address(this)) >= amountA, "Insufficient TokenA");
        require(IERC20(tokenB).balanceOf(address(this)) >= amountB, "Insufficient TokenB");

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: tokenA,
            token1: tokenB,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amountA,
            amount1Desired: amountB,
            amount0Min: 0,
            amount1Min: 0,
            recipient: msg.sender,
            deadline: block.timestamp + 120
        });

        (tokenId, liquidity, amount0, amount1) = positionManager.mint(params);

        // Refund unused tokens
        if (amountA > amount0) {
            IERC20(tokenA).transfer(msg.sender, amountA - amount0);
        }
        if (amountB > amount1) {
            IERC20(tokenB).transfer(msg.sender, amountB - amount1);
        }
    }
}
