// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;


contract addy {
    constructor(){}

    function addressToBytes32(address _addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function saltString(string calldata _input) public pure returns (bytes32) {
        return keccak256(bytes(_input));
    }


}