// contracts/SuperTokenFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin's IERC20Metadata and Clones library
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

// Import Interfaces
import "./interfaces/ITokenSwap.sol";
import "./interfaces/IEqualFiToken.sol";
import "./interfaces/IFlashLoanReceiver2.sol";

// Import Contracts
import "./SuperToken3.sol";
import "./SuperTokenLPFactory.sol";

/**
 * @title SuperTokenFactory
 * @dev Factory contract for deploying SuperToken2 contracts and their associated LPToken contracts using the ERC20Factory and Clones library.
 */
contract SuperTokenFactory {
    using Clones for address;

    // Address of the SuperToken2 implementation
    address public immutable superTokenImplementation;

    // Instance of the ERC20Factory to create LPToken contracts
    SuperTokenLPFactory public immutable erc20Factory;

    // Event emitted when a new SuperToken clone is created
    event SuperTokenCreated(
        address indexed superTokenAddress,
        address indexed lpTokenAddress,
        string name,
        string symbol,
        IERC20Metadata[] underlyingTokens,
        address tokenIface,
        uint256 collateralizationRatio,
        uint256[] requiredAmountsPerSuperToken
    );

    /**
     * @dev Constructor sets the SuperToken2 implementation address and ERC20Factory address.
     * @param _superTokenImplementation Address of the deployed SuperToken2 implementation.
     * @param _erc20Factory Address of the deployed ERC20Factory contract.
     */
    constructor(address _superTokenImplementation, address _erc20Factory) {
        require(
            _superTokenImplementation != address(0),
            "SuperTokenFactory: implementation address cannot be zero"
        );
        require(
            _erc20Factory != address(0),
            "SuperTokenFactory: ERC20Factory address cannot be zero"
        );
        superTokenImplementation = _superTokenImplementation;
        erc20Factory = SuperTokenLPFactory(_erc20Factory);
    }

    /**
     * @dev Creates a new SuperToken2 clone contract along with its LPToken.
     * @param name Name of the SuperToken.
     * @param symbol Symbol of the SuperToken.
     * @param _underlyingTokens Array of underlying ERC20Metadata token addresses.
     * @param _token Address of the IEqualFiToken contract with burnFrom functionality.
     * @param _collateralizationRatio The collateralization ratio for loans (e.g., 150 for 150%)
     * @param _requiredAmountsPerSuperToken Array specifying required amounts per underlying token to mint one SuperToken.
     * @return superToken Address of the newly created SuperToken2 clone contract.
     * @return lpToken Address of the newly created LPToken contract.
     */
    function createSuperToken(
        string memory name,
        string memory symbol,
        IERC20Metadata[] memory _underlyingTokens,
        IEqualFiToken _token,
        uint256 _collateralizationRatio,
        uint256[] memory _requiredAmountsPerSuperToken
    ) public returns (address superToken, address lpToken) {
        // Validate the number of underlying tokens
        require(
            _underlyingTokens.length >= 2 && _underlyingTokens.length <= 10,
            "SuperTokenFactory: must have between 2 and 10 underlying tokens"
        );

        // Validate required amounts length
        require(
            _requiredAmountsPerSuperToken.length == _underlyingTokens.length,
            "SuperTokenFactory: required amounts length mismatch"
        );

        //erc20Factory.grantRole(erc20Factory.DEFAULT_ADMIN_ROLE(), address(this));

        // Create a clone of the SuperToken2 implementation
        superToken = superTokenImplementation.clone();

        // Initialize the clone with the provided parameters
        SuperToken3(payable(superToken)).initialize(
            _underlyingTokens,
            _token,
            msg.sender, // Assign the caller as the admin
            _collateralizationRatio,
            _requiredAmountsPerSuperToken,
            lpToken
        );

        // Create a new LPToken using the ERC20Factory
        string memory lpTokenName = string(abi.encodePacked(name, " LP Token"));
        string memory lpTokenSymbol = string(abi.encodePacked(symbol, "-LP"));
        lpToken = address(erc20Factory.createLPToken(lpTokenName, lpTokenSymbol, superToken));
        require(lpToken != address(0), "SuperTokenFactory: LPToken creation failed");

        // Grant MINTER_ROLE and BURNER_ROLE to SuperToken2 in the LPToken contract
        //LPToken(lpToken).grantRole(LPToken(lpToken).MINTER_ROLE(), msg.sender);
        //LPToken(lpToken).grantRole(LPToken(lpToken).BURNER_ROLE(), msg.sender);

        // Emit event with relevant details
        emit SuperTokenCreated(
            superToken,
            lpToken,
            name,
            symbol,
            _underlyingTokens,
            address(_token),
            _collateralizationRatio,
            _requiredAmountsPerSuperToken
        );

        return (superToken, lpToken);
    }
}
