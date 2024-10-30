// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin Contracts
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Import Uniswap V3 Interfaces
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

/**
 * @title TokenSwap
 * @dev External contract to handle swapping approved tokens to USDC using Uniswap V3.
 */
contract TokenSwap is AccessControl, ReentrancyGuard {
    // ========================== Roles ==========================
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ========================== State Variables ==========================
    ISwapRouter public swapRouter;
    address public immutable USDC; // USDC token address

    // Approved tokens that can be swapped to USDC
    mapping(address => bool) public approvedTokens;

    // Pool fee for Uniswap V3 swaps (e.g., 0.3% fee)
    uint24 public constant POOL_FEE = 3000;

    // ========================== Events ==========================
    event TokenApproved(address indexed token);
    event TokenRevoked(address indexed token);
    event TokenSwapped(address indexed user, address indexed inputToken, uint256 inputAmount, uint256 usdcReceived);

    // ========================== Constructor ==========================
    /**
     * @dev Initializes the contract by setting the swap router and USDC address.
     * Grants the deployer the DEFAULT_ADMIN_ROLE and ADMIN_ROLE.
     * @param _swapRouter Address of the Uniswap V3 Swap Router.
     * @param _usdc Address of the USDC token.
     */
    constructor(ISwapRouter _swapRouter, address _usdc) {
        require(address(_swapRouter) != address(0), "Invalid swap router address");
        require(_usdc != address(0), "Invalid USDC address");

        swapRouter = _swapRouter;
        USDC = _usdc;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ========================== Modifiers ==========================

    /**
     * @dev Ensures that only approved tokens can be swapped.
     * @param token Address of the token to check.
     */
    modifier onlyApprovedToken(address token) {
        require(approvedTokens[token], "Token not approved for swapping");
        _;
    }

    // ========================== Admin Functions ==========================

    /**
     * @dev Approves a new token for swapping to USDC.
     * @param token Address of the token to approve.
     */
    function approveToken(address token) external onlyRole(ADMIN_ROLE) {
        require(token != USDC, "USDC is already the target token");
        require(token != address(0), "Invalid token address");
        approvedTokens[token] = true;
        emit TokenApproved(token);
    }

    /**
     * @dev Revokes a token's approval for swapping to USDC.
     * @param token Address of the token to revoke.
     */
    function revokeToken(address token) external onlyRole(ADMIN_ROLE) {
        require(approvedTokens[token], "Token is not approved");
        approvedTokens[token] = false;
        emit TokenRevoked(token);
    }

    /**
     * @dev Updates the Uniswap V3 Swap Router address.
     * @param _swapRouter New Swap Router address.
     */
    function updateSwapRouter(ISwapRouter _swapRouter) external onlyRole(ADMIN_ROLE) {
        require(address(_swapRouter) != address(0), "Invalid swap router address");
        swapRouter = _swapRouter;
    }

    // ========================== Swap Function ==========================

    /**
     * @dev Swaps a specified amount of an approved token to USDC.
     * @param inputToken Address of the token to swap from.
     * @param amountIn Amount of the input token to swap.
     * @param amountOutMinimum Minimum amount of USDC expected from the swap to protect against slippage.
     * @param deadline Unix timestamp after which the swap is no longer valid.
     * @return amountOut Amount of USDC received from the swap.
     */
    function swapToUSDC(
        address inputToken,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    )
        external
        nonReentrant
        onlyApprovedToken(inputToken)
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "Input amount must be greater than zero");

        IERC20(inputToken).transferFrom(msg.sender, address(this), amountIn);
        IERC20(inputToken).approve(address(swapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: inputToken,
                tokenOut: USDC,
                fee: POOL_FEE,
                recipient: msg.sender,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            });

        amountOut = swapRouter.exactInputSingle(params);

        require(amountOut >= amountOutMinimum, "Insufficient output amount");

        emit TokenSwapped(msg.sender, inputToken, amountIn, amountOut);
    }

    // ========================== View Functions ==========================

    /**
     * @dev Checks if a token is approved for swapping.
     * @param token Address of the token to check.
     * @return isApproved Boolean indicating approval status.
     */
    function isTokenApproved(address token) external view returns (bool isApproved) {
        isApproved = approvedTokens[token];
    }
}
