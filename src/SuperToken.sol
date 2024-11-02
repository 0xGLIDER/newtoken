// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract SuperToken is ERC20, ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    IERC20[] public underlyingTokens;
    uint256[] public amountsPerSuperToken;

    bytes32 public constant _ADMIN = keccak256("_ADMIN");

    uint8 private constant _decimals = 18;

    event Deposit(address indexed user, uint256 amount);
    event Redeem(address indexed user, uint256 amount);

    /**
     * @dev Constructor for SuperToken.
     * @param name Name of the Super Token.
     * @param symbol Symbol of the Super Token.
     * @param _underlyingTokens Array of underlying ERC20 token addresses.
     * @param _amountsPerSuperToken Array of amounts required per Super Token for each underlying token.
     */
    constructor(
        string memory name,
        string memory symbol,
        IERC20[] memory _underlyingTokens,
        uint256[] memory _amountsPerSuperToken
    ) ERC20(name, symbol) {
        require(
            _underlyingTokens.length >= 2 && _underlyingTokens.length <= 10,
            "Must have between 2 and 10 underlying tokens"
        );
        require(
            _underlyingTokens.length == _amountsPerSuperToken.length,
            "Tokens and amounts length mismatch"
        );

        underlyingTokens = _underlyingTokens;
        amountsPerSuperToken = _amountsPerSuperToken;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev Allows users to deposit underlying tokens and mint Super Tokens.
     * @param superAmount The amount of Super Tokens to mint.
     */
    function deposit(uint256 superAmount) public nonReentrant {
        require(superAmount > 0, "Amount must be greater than zero");

        uint256 len = underlyingTokens.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 totalAmount = superAmount * amountsPerSuperToken[i];
            uint256 balanceBefore = underlyingTokens[i].balanceOf(address(this));
            underlyingTokens[i].safeTransferFrom(msg.sender, address(this), totalAmount);
            uint256 balanceAfter = underlyingTokens[i].balanceOf(address(this));
            require(
                balanceAfter - balanceBefore == totalAmount,
                "Incorrect token amount received"
            );
        }

        _mint(msg.sender, superAmount);
        emit Deposit(msg.sender, superAmount);
    }

    /**
     * @dev Allows users to burn Super Tokens and redeem underlying tokens.
     * @param superAmount The amount of Super Tokens to redeem.
     */
    function redeem(uint256 superAmount) public nonReentrant {
        require(superAmount > 0, "Amount must be greater than zero");
        require(
            balanceOf(msg.sender) >= superAmount,
            "Insufficient Super Tokens"
        );

        _burn(msg.sender, superAmount);

        uint256 len = underlyingTokens.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 totalAmount = superAmount * amountsPerSuperToken[i];
            underlyingTokens[i].safeTransfer(msg.sender, totalAmount);
        }

        emit Redeem(msg.sender, superAmount);
    }
}
