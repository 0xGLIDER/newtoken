// contracts/SuperToken3Factory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin Contracts
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Import Contracts and Interfaces
import "./SuperToken3.sol";
import "./SuperTokenLPFactory.sol";
import "./LPToken.sol";

/**
 * @title SuperToken3Factory
 * @dev Factory contract to deploy and initialize multiple instances of SuperToken3 along with their LPToken contracts.
 */
contract SuperToken3Factory is Ownable {
    // Reference to the SuperTokenLPFactory contract
    SuperTokenLPFactory public lpFactory;

    // Array to keep track of all deployed SuperToken3 contracts
    SuperToken3[] public allSuperTokens;

    // Event emitted when a new SuperToken3 is deployed
    event SuperToken3Created(
        address indexed superTokenAddress,
        address indexed lpTokenAddress,
        address indexed admin,
        string name,
        string symbol,
        IERC20Metadata[] underlyingTokens,
        address tokenIface,
        uint256 collateralizationRatio,
        uint256[] requiredAmountsPerSuperToken
    );

    /**
     * @dev Constructor sets the address of the SuperTokenLPFactory.
     * @param _lpFactory Address of the deployed SuperTokenLPFactory contract.
     */
    constructor(address _lpFactory) Ownable(msg.sender) {
        require(_lpFactory != address(0), "Factory: LPFactory address cannot be zero");
        lpFactory = SuperTokenLPFactory(payable(_lpFactory));
    }

    /**
     * @dev Deploys a new SuperToken3 contract and its associated LPToken, then initializes it.
     * @param name Name of the LPToken.
     * @param symbol Symbol of the LPToken.
     * @param _underlyingTokens Array of underlying token contracts.
     * @param _token Address of the IEqualFiToken contract.
     * @param admin Address to be granted ADMIN_ROLE.
     * @param _collateralizationRatio Collateralization ratio (e.g., 150 for 150%).
     * @param _requiredAmountsPerSuperToken Array of required amounts per underlying token for 1 SuperToken.
     * @return superTokenAddress The address of the newly deployed SuperToken3 contract.
     * @return lpTokenAddress The address of the newly deployed LPToken contract.
     */
    function createSuperToken3(
        string memory name,
        string memory symbol,
        IERC20Metadata[] memory _underlyingTokens,
        IEqualFiToken _token,
        address admin,
        uint256 _collateralizationRatio,
        uint256[] memory _requiredAmountsPerSuperToken
    ) external onlyOwner returns (address superTokenAddress, address lpTokenAddress) {
        // Validate input lengths
        require(
            _underlyingTokens.length >= 2 && _underlyingTokens.length <= 10,
            "Factory: must have between 2 and 10 underlying tokens"
        );
        require(
            _requiredAmountsPerSuperToken.length == _underlyingTokens.length,
            "Factory: required amounts length mismatch"
        );

        // Deploy the SuperToken3 contract
        SuperToken3 superToken = new SuperToken3();
        superTokenAddress = address(superToken);

        // Deploy the LPToken via SuperTokenLPFactory
        LPToken lpToken = lpFactory.createLPToken(name, symbol, superTokenAddress);
        lpTokenAddress = address(lpToken);
        require(lpTokenAddress != address(0), "Factory: LPToken creation failed");

        // Initialize the SuperToken3 contract
        superToken.initialize(
            _underlyingTokens,
            _token,
            admin,
            _collateralizationRatio,
            _requiredAmountsPerSuperToken,
            lpTokenAddress
        );

        // Track the deployed SuperToken3 instance
        allSuperTokens.push(superToken);

        // Emit an event with deployment details
        emit SuperToken3Created(
            superTokenAddress,
            lpTokenAddress,
            admin,
            name,
            symbol,
            _underlyingTokens,
            address(_token),
            _collateralizationRatio,
            _requiredAmountsPerSuperToken
        );

        return (superTokenAddress, lpTokenAddress);
    }

    /**
     * @dev Returns the total number of SuperToken3 contracts deployed.
     * @return The count of deployed SuperToken3 contracts.
     */
    function getSuperTokensCount() external view returns (uint256) {
        return allSuperTokens.length;
    }

    /**
     * @dev Returns the SuperToken3 contract at a specific index.
     * @param index The index in the allSuperTokens array.
     * @return The SuperToken3 contract instance at the specified index.
     */
    function getSuperTokenAt(uint256 index) external view returns (SuperToken3) {
        require(index < allSuperTokens.length, "Factory: Index out of bounds");
        return allSuperTokens[index];
    }

    // Fallback and receive functions to prevent ETH transfers
    fallback() external payable {
        revert("Factory: Cannot accept ETH");
    }

    receive() external payable {
        revert("Factory: Cannot accept ETH");
    }
}
