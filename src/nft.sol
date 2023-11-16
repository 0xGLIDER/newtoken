// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import {iface} from "./iface.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {hextool} from "./hex.sol";

contract NFT is ERC721URIStorage, AccessControl {
    
    uint256 private nextTokenId;

    uint256 private cap;

    uint256 public totalSupply;

    uint256 public tokenBalanceRequired;

    iface public token;

    string public currentTokenURI;

    bytes32 public constant _MINT = keccak256("_MINT");

    bytes32 public constant _ADMIN = keccak256("_ADMIN");
    

    constructor(string memory tokenURI, uint256 initialCap, iface tokenContract, uint256 setTokenBalanceRequired) ERC721("NewNFT", "NFT") {
        currentTokenURI = tokenURI;
        cap = initialCap;
        token = tokenContract;
        tokenBalanceRequired = setTokenBalanceRequired;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function mintNFT() public returns (uint256) {
        //require(hasRole(_MINT, msg.sender), " NFT: No");
        require(token.balanceOf(msg.sender) >= tokenBalanceRequired);
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tokenId)));
        _setTokenURI(tokenId, newID);
        _safeMint(msg.sender, tokenId);
        totalSupply = ++totalSupply;
        require(totalSupply <= cap,"NFT: Supply Cap");
        return tokenId;
    }
    
    function burnNFT(uint256 tokenId) public {
        address owner = _ownerOf(tokenId);
        require(msg.sender == owner,"NFT: Not owner");
        _burn(tokenId);
        totalSupply = --totalSupply;
        
    }

    function setURI(string memory newURI) public returns (string memory) {
        require(hasRole(_ADMIN, msg.sender), "NFT: Need Admin");
        currentTokenURI = newURI;
        return currentTokenURI;
    } 


    function userUpdateURI (uint256 tid) public returns (string memory) {
        address owner = _ownerOf(tid);
        require(msg.sender == owner, "NFT: Not owner");
        string memory i = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tid)));
        _setTokenURI(tid, i);
        return i;
    }

    function setRequiredTokenAmount (uint256 rta) public returns (uint256) {
        require(hasRole(_ADMIN, msg.sender), "NFT: Need Admin");
        tokenBalanceRequired = rta;
        return rta;
    }

    function hashUserAddress (uint256 eid) public view returns (bytes32) {
        address userAddress = address(msg.sender);
        uint256 userEID = eid;
        bytes32 hashedAddress = keccak256(abi.encodePacked(userAddress, userEID));
        return hashedAddress;
    }

   function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721URIStorage, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
    

}