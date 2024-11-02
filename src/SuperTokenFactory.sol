// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin's IERC20Metadata interface
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Import SuperToken contract (which includes TokenIface and ITokenSwap interfaces)
import "./SuperToken2.sol";


/**
 * @title SuperTokenFactory
 * @dev Factory contract for deploying SuperToken contracts.
 */
contract SuperTokenFactory {
    
    // Event emitted when a new SuperToken is created
    event SuperTokenCreated(
        address indexed superTokenAddress,
        string name,
        string symbol,
        IERC20Metadata[] underlyingTokens,
        uint256[] amountsPerSuperToken,
        address tokenIface,
        address tokenSwap
    );

    /**
     * @dev Creates a new SuperToken contract.
     * @param name Name of the SuperToken.
     * @param symbol Symbol of the SuperToken.
     * @param _underlyingTokens Array of underlying ERC20Metadata token addresses.
     * @param _amountsPerSuperToken Array of amounts required per SuperToken for each underlying token.
     * @param _token Address of the TokenIface contract with burnFrom functionality.
     * @param _tokenSwap Address of the TokenSwap contract.
     * @return Address of the newly created SuperToken contract.
     */
    function createSuperToken(
        string memory name,
        string memory symbol,
        IERC20Metadata[] memory _underlyingTokens,
        uint256[] memory _amountsPerSuperToken,
        TokenIface _token,
        ITokenSwap _tokenSwap
    ) public returns (address) {
        // Validate input arrays
        require(
            _underlyingTokens.length >= 2 && _underlyingTokens.length <= 10,
            "Must have between 2 and 10 underlying tokens"
        );
        require(
            _underlyingTokens.length == _amountsPerSuperToken.length,
            "Tokens and amounts length mismatch"
        );

        // Deploy a new SuperToken contract
        SuperToken superToken = new SuperToken(
            name,
            symbol,
            _underlyingTokens,
            _amountsPerSuperToken,
            _token,
            _tokenSwap
        );

        // Emit event with relevant details
        emit SuperTokenCreated(
            address(superToken),
            name,
            symbol,
            _underlyingTokens,
            _amountsPerSuperToken,
            address(_token),
            address(_tokenSwap)
        );

        // Grant ADMIN_ROLE and DEFAULT_ADMIN_ROLE to the caller
        superToken.grantRole(superToken.ADMIN_ROLE(), msg.sender);
        superToken.grantRole(superToken.DEFAULT_ADMIN_ROLE(), msg.sender);

        return address(superToken);
    }
}
