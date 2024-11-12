// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./loans4.sol"; 

contract LendingFactory {
    event LendingCreated(address indexed lendingAddress);

    function createLending(
        IERC20 _stablecoin,
        IERC20 _collateralToken,
        TokenIface _token,
        bytes32 salt // A unique salt for the contract address
    ) external returns (address) {
        address lendingAddress = _deployLending(_stablecoin, _collateralToken, _token, salt);
        emit LendingCreated(lendingAddress);
        return lendingAddress;
    }

    function _deployLending(
        IERC20 _stablecoin,
        IERC20 _collateralToken,
        TokenIface _token,
        bytes32 salt
    ) internal returns (address) {
        // Use CREATE2 to deploy the StablecoinLending contract
        StablecoinLending lending = new StablecoinLending{salt: salt}(_stablecoin, _collateralToken, _token);
        return address(lending);
    }

    // To get the address of the deployed contract
    function getLendingAddress(
        IERC20 _stablecoin,
        IERC20 _collateralToken,
        TokenIface _token,
        bytes32 salt
    ) external view returns (address) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(type(StablecoinLending).creationCode, abi.encode(_stablecoin, _collateralToken, _token))
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this), // Factory address
            salt, // Unique salt
            bytecodeHash // Hash of the bytecode
        )))));
    }

    function getBytes32(uint256 _value) external pure returns (bytes32) {
        bytes32 value = keccak256(abi.encodePacked(_value));
        
        return bytes32(value);
    }
}