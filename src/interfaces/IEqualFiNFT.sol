// contracts/interfaces/IFlashLoanReceiver.sol
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
interface IEqualFiNFT {
    /**
     * @dev Returns the URI of the specified NFT.
     * @param tokenId The ID of the NFT.
     * @return The URI string of the NFT.
     */
    function tokenURI(uint256 tokenId) external view returns (string memory);

    /**
     * @dev Returns the NFT ownership information of a user.
     * @param user The address of the user.
     * @return The NFT level of the user.
     */
    function nftOwnerInfo(address user) external view returns (uint256);
}