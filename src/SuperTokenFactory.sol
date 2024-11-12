// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin Contracts
import "@openzeppelin/contracts/access/AccessControl.sol";

// Import the SuperToken3 contract
import "./SuperToken6.sol";

/**
 * @title SuperToken3Factory
 * @dev Factory contract to deploy instances of SuperToken3.
 */
contract SuperToken3Factory {
    // Array to keep track of deployed SuperToken3 instances
    SuperToken6[] public deployedSuperTokens;

    // Event emitted when a new SuperToken3 is deployed
    event SuperToken3Deployed(address indexed superToken3Address);

    /**
     * @dev Deploys a new SuperToken3 contract.
     * @param _underlyingTokens Array of underlying tokens.
     * @param _token The EqualFiToken.
     * @param _lpFactory The SuperTokenLPFactory.
     * @param _collateralizationRatio The collateralization ratio.
     * @param _requiredAmountsPerSuperToken The required amounts per SuperToken.
     * @param poolName Name of the LPToken.
     * @param poolSymbol Symbol of the LPToken.
     * @param adminAddress Address to be granted DEFAULT_ADMIN_ROLE on SuperToken3.
     * @return The address of the deployed SuperToken3 contract.
     */
    function createSuperToken3(
        IERC20Metadata[] memory _underlyingTokens,
        IEqualFiToken _token,
        SuperTokenLPFactory _lpFactory,
        uint256 _collateralizationRatio,
        uint256[] memory _requiredAmountsPerSuperToken,
        string memory poolName,
        string memory poolSymbol,
        IERC721 nft,
        address adminAddress
    ) public returns (address) {
        // Deploy new SuperToken3 instance
        SuperToken6 superToken = new SuperToken6(
            _underlyingTokens,
            _token,
            _lpFactory,
            _collateralizationRatio,
            _requiredAmountsPerSuperToken
        );

        // Initialize the pool
        superToken.initializePool(poolName, poolSymbol, adminAddress, nft);

        // Transfer roles to the specified adminAddress
        superToken.grantRole(superToken.DEFAULT_ADMIN_ROLE(), adminAddress);
        superToken.grantRole(superToken.ADMIN_ROLE(), adminAddress);

        // Renounce roles from the factory
        superToken.renounceRole(superToken.DEFAULT_ADMIN_ROLE(), address(this));
        superToken.renounceRole(superToken.ADMIN_ROLE(), address(this));

        // Keep track of deployed SuperToken3 instances
        deployedSuperTokens.push(superToken);

        // Emit event
        emit SuperToken3Deployed(address(superToken));

        return address(superToken);
    }

    /**
     * @dev Returns the number of SuperToken3 contracts deployed by this factory.
     */
    function getDeployedTokensCount() external view returns (uint256) {
        return deployedSuperTokens.length;
    }

    /**
     * @dev Returns the address of a deployed SuperToken3 contract.
     * @param index The index of the deployed SuperToken3 contract.
     */
    function getDeployedToken(uint256 index) external view returns (address) {
        require(index < deployedSuperTokens.length, "Index out of bounds");
        return address(deployedSuperTokens[index]);
    }
}
