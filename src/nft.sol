// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import {iface} from "./iface.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {hextool} from "./hex.sol";

contract NFT is ERC721URIStorage, AccessControl {
    
    uint256 private nextTokenId;
    uint256 private cap;
    uint256 public totalSupply;
    uint256 public tokenBalanceRequired;
    IERC20 public token;
    string public currentTokenURI;
    uint256 public txFee;
    address public vault;
    bytes32 public constant _MINT = keccak256("_MINT");
    bytes32 public constant _ADMIN = keccak256("_ADMIN");

    struct SupplyInfo {
        uint256 goldCap;
        uint256 silverCap;
        uint256 bronzeCap;
        uint256 goldSupply;
        uint256 silverSupply;
        uint256 bronzeSupply;
    }

    SupplyInfo public supplyInfo;

    struct NFTOwnerInfo {
        bytes32 level;
        bool hasNFT;

    }

    mapping(address => NFTOwnerInfo) public nftOwnerInfo;

    constructor(
        string memory _tokenURI, 
        uint256 _initialCap, 
        IERC20 _tokenContract, 
        uint256 _setTokenBalanceRequired, 
        uint256 _setTxFee, 
        address _setVault
        ) ERC721("NewNFT", "NFT") {
        currentTokenURI = _tokenURI;
        cap = _initialCap;
        token = _tokenContract;
        tokenBalanceRequired = _setTokenBalanceRequired;
        txFee = _setTxFee;
        vault = _setVault;
        initializeSupplyInfo();
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    function initializeSupplyInfo() internal {
        supplyInfo = SupplyInfo(50,100,200,0,0,0);
    }

    function mintNFT() public returns (uint256) {
        require(token.balanceOf(_msgSender()) >= tokenBalanceRequired);
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tokenId)));
        _setTokenURI(tokenId, newID);
        _safeMint(_msgSender(), tokenId);
        totalSupply = ++totalSupply;
        require(totalSupply <= cap,"NFT: Supply Cap");
        return tokenId;
    }

    function mintGoldNFT() public returns (uint256) {
        require(token.balanceOf(_msgSender()) >= tokenBalanceRequired);
        require(nftOwnerInfo[_msgSender()].hasNFT == false, "Can't mint more than one NFT");
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, hextool.toHex(hashUserAddress2("GOLD", tokenId)));
        _setTokenURI(tokenId, newID);
        _safeMint(_msgSender(), tokenId);
        totalSupply = ++totalSupply;
        ++supplyInfo.goldSupply;
        NFTOwnerInfo memory n = NFTOwnerInfo({
            level: hashUserAddress2("GOLD", tokenId),
            hasNFT: true
        });

        nftOwnerInfo[_msgSender()] = n;
        require(supplyInfo.goldSupply <= supplyInfo.goldCap,"NFT: Supply Cap");
        return tokenId;
    }

    function mintSilverNFT() public returns (uint256) {
        require(token.balanceOf(_msgSender()) >= tokenBalanceRequired);
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, hextool.toHex(hashUserAddress2("SILVER", tokenId)));
        _setTokenURI(tokenId, newID);
        _safeMint(_msgSender(), tokenId);
        totalSupply = ++totalSupply;
        ++supplyInfo.silverSupply;
        NFTOwnerInfo memory n = NFTOwnerInfo({
            level: hashUserAddress2("SILVER", tokenId),
            hasNFT: true
        });

        nftOwnerInfo[_msgSender()] = n;
        require(totalSupply <= supplyInfo.silverCap,"NFT: Supply Cap");
        return tokenId;
    }

    function mintBronzeNFT() public returns (uint256) {
        require(token.balanceOf(_msgSender()) >= tokenBalanceRequired);
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, hextool.toHex(hashUserAddress2("BRONZE", tokenId)));
        _setTokenURI(tokenId, newID);
        _safeMint(_msgSender(), tokenId);
        ++totalSupply;
        ++supplyInfo.bronzeSupply;
        NFTOwnerInfo memory n = NFTOwnerInfo({
            level: hashUserAddress2("BRONZE", tokenId),
            hasNFT: true
        });

        nftOwnerInfo[_msgSender()] = n;
        require(supplyInfo.bronzeSupply <= supplyInfo.bronzeCap,"NFT: Supply Cap");
        return tokenId;
    }
    
    function burnNFT(uint256 tokenId) public {
        require(_msgSender() == _ownerOf(tokenId), "NFT: Not owner");

        bytes32 ha = hashUserAddress2("GOLD", tokenId);
        require(ha == hashUserAddress2("GOLD", tokenId), "Invalid hash check");

        _update(address(0), tokenId, _msgSender());
        supplyInfo.goldSupply--;
    }

    function setURI(string memory newURI) public returns (string memory) {
        require(hasRole(_ADMIN, _msgSender()), "NFT: Need Admin");
        currentTokenURI = newURI;
        return currentTokenURI;
    } 

    function userUpdateURI (uint256 tid) public returns (string memory) {
        address owner = _ownerOf(tid);
        require(_msgSender() == owner, "NFT: Not owner");
        string memory i = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tid)));
        _setTokenURI(tid, i);
        return i;
    }

    function setRequiredTokenAmount (uint256 rta) public returns (uint256) {
        require(hasRole(_ADMIN, _msgSender()), "NFT: Need Admin");
        tokenBalanceRequired = rta;
        return rta;
    }

    function setTxFee(uint256 _newFee) external {
        txFee = _newFee;
    }

    function setSupplyCaps(uint256 _newGS, uint256 _newSS, uint256 _newBS) public {
        supplyInfo.goldCap = _newGS;
        supplyInfo.silverCap = _newSS;
        supplyInfo.bronzeCap = _newBS;
    }

    function hashUserAddress(uint256 eid) public view returns (bytes32) {
    return keccak256(abi.encodePacked(msg.sender, eid));
}

    function hashUserAddress2(string memory _level, uint256 _eid) public view returns (bytes32) {
    return keccak256(abi.encodePacked(msg.sender, _level, _eid));
}

    function _update(address to, uint256 tokenId, address from) internal virtual override(ERC721) returns (address) {
        if (from == address(0)){
            super._update(to, tokenId, from);
        } else if (from != address(0)) {
            token.transferFrom(_msgSender(), vault, txFee);
            super._update(to, tokenId, from);
        }
        return from;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721URIStorage, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function moveERC20(IERC20 _ERC20, address _dest, uint _ERC20Amount) public {
        //require(hasRole(_RESCUE, _msgSender()));
        IERC20(_ERC20).transfer(_dest, _ERC20Amount);
    }

    function ethRescue(address payable _dest, uint _etherAmount) public {
        //require(hasRole(_RESCUE, _msgSender()));
        _dest.transfer(_etherAmount);
    }
    
}