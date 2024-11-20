// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/Create3.sol";
import "./OmniChainToken.sol"; // Assuming the token contract is in the same directory

/**
 * @title EqualFIOmnichainTokenFactory
 * @notice Factory contract for deterministic deployment of EqualFIOmnichainToken instances using Create3
 */
contract EqualFIOmnichainTokenFactory is Ownable {
    // Event emitted when a new token is deployed
    event TokenDeployed(
        address indexed tokenAddress,
        string name,
        string symbol,
        address lzEndpoint,
        address delegate,
        address admin,
        bytes32 salt
    );

    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @notice Deploys a new EqualFIOmnichainToken with deterministic address
     * @param name Token name
     * @param symbol Token symbol
     * @param lzEndpoint LayerZero endpoint address
     * @param delegate Address to receive initial delegation
     * @param admin Address to receive admin role
     * @param salt Unique salt for deterministic address generation
     * @return tokenAddress The address of the deployed token contract
     */
    function deployToken(
        string memory name,
        string memory symbol,
        address lzEndpoint,
        address delegate,
        address admin,
        bytes32 salt
    ) external onlyOwner returns (address tokenAddress) {
        // Create the initialization bytecode
        bytes memory creationCode = abi.encodePacked(
            type(EqualFIOmnichainToken).creationCode,
            abi.encode(name, symbol, lzEndpoint, delegate, admin)
        );

        // Deploy using Create3
        tokenAddress = Create3.create3(
            salt,
            creationCode
        );

        emit TokenDeployed(
            tokenAddress,
            name,
            symbol,
            lzEndpoint,
            delegate,
            admin,
            salt
        );
    }

    /**
     * @notice Computes the deterministic address for a token deployment
     * @param salt The salt to be used for address generation
     * @return The computed address where the token would be deployed
     */
    function computeTokenAddress(bytes32 salt) external view returns (address) {
        return Create3.addressOf(salt);
    }

    /**
     * @notice Checks if a token has already been deployed at the computed address
     * @param salt The salt used for address generation
     * @return true if a contract exists at the computed address
     */
    function isTokenDeployed(bytes32 salt) external view returns (bool) {
        return Create3.codeSize(Create3.addressOf(salt)) > 0;
    }
}