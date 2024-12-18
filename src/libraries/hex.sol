// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

/**
 * @title hextool
 * @dev A library for converting bytes data to hexadecimal string representation.
 *      This library provides functions to convert bytes32 data into a readable hex format.
 */
library hextool {

    /**
     * @dev Converts a bytes32 value to its hexadecimal string representation with "0x" prefix.
     * @param data The bytes32 data to be converted.
     * @return The hexadecimal string representation of the input data.
     */
    function toHex(bytes32 data) public pure returns (string memory) {
        return string(abi.encodePacked("0x", toHex16(bytes16(data)), toHex16(bytes16(data << 128))));
    }

    /**
     * @dev Converts a bytes16 value to its hexadecimal string representation as bytes32.
     *      This function uses bitwise operations to convert each byte to its hex value.
     * @param data The bytes16 data to be converted.
     * @return result The hexadecimal representation of the input as bytes.
     */
    function toHex16(bytes16 data) internal pure returns (bytes32 result) {
        result =
            (bytes32(data) & 0xFFFFFFFFFFFFFFFF000000000000000000000000000000000000000000000000) |
            ((bytes32(data) & 0x0000000000000000FFFFFFFFFFFFFFFF00000000000000000000000000000000) >> 64);
        result =
            (result & 0xFFFFFFFF000000000000000000000000FFFFFFFF000000000000000000000000) |
            ((result & 0x00000000FFFFFFFF000000000000000000000000FFFFFFFF0000000000000000) >> 32);
        result =
            (result & 0xFFFF000000000000FFFF000000000000FFFF000000000000FFFF000000000000) |
            ((result & 0x0000FFFF000000000000FFFF000000000000FFFF000000000000FFFF00000000) >> 16);
        result =
            (result & 0xFF000000FF000000FF000000FF000000FF000000FF000000FF000000FF000000) |
            ((result & 0x00FF000000FF000000FF000000FF000000FF000000FF000000FF000000FF0000) >> 8);
        result =
            ((result & 0xF000F000F000F000F000F000F000F000F000F000F000F000F000F000F000F000) >> 4) |
            ((result & 0x0F000F000F000F000F000F000F000F000F000F000F000F000F000F000F000F00) >> 8);
        result = bytes32(
            0x3030303030303030303030303030303030303030303030303030303030303030 +
                uint256(result) +
                (((uint256(result) + 0x0606060606060606060606060606060606060606060606060606060606060606) >> 4) &
                    0x0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F)
        );
    }
}
