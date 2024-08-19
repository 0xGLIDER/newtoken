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
    uint256 public totalSupply;
    uint256 public tokenBalanceRequired;
    IERC20 public token;
    iface public Iface;
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

    struct BalanceRequired {
        uint256 goldBR;
        uint256 silverBR;
        uint256 bronzeBR;
    }

    BalanceRequired public balanceRequired;

    struct NFTOwnerInfo {
        uint256 level;
        bool hasNFT;
    }

    mapping(address => NFTOwnerInfo) public nftOwnerInfo;

    constructor(
        string memory _tokenURI, 
        IERC20 _tokenContract, 
        uint256 _setTokenBalanceRequired,  
        address _setVault,
        address _ifaceAddress
        ) ERC721("NewNFT", "NFT") {
        currentTokenURI = _tokenURI;
        token = _tokenContract;
        tokenBalanceRequired = _setTokenBalanceRequired;
        txFee = 15 ether;
        vault = _setVault;
        Iface = iface(_ifaceAddress);
        supplyInfo = SupplyInfo({
            goldCap: 50, 
            silverCap: 100, 
            bronzeCap: 200, 
            goldSupply: 0, 
            silverSupply: 0, 
            bronzeSupply: 0
        });
        balanceRequired = BalanceRequired({
            goldBR: 10000 ether,
            silverBR: 5000 ether,
            bronzeBR: 2500 ether
        });
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    function mintNFT(uint256 _level) public payable returns (uint256) {
        require(_level >= 1 && _level <= 3, "Invalid level");
        require(!nftOwnerInfo[_msgSender()].hasNFT, "Can't mint more than one NFT");
    
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tokenId)));
        _setTokenURI(tokenId, newID);
        _safeMint(_msgSender(), tokenId);

        totalSupply = ++totalSupply;
    
        // Update level-specific supply and check cap
        if (_level == 1) {
            require(Iface.balanceOf(_msgSender()) >= tokenBalanceRequired);
            require(msg.value == 0.025 ether);
            require(supplyInfo.goldSupply++ < supplyInfo.goldCap, "NFT: Gold supply cap exceeded");
            Iface.mintTo(_msgSender(), 10000 ether);
        } else if (_level == 2) {
            require(Iface.balanceOf(_msgSender()) >= tokenBalanceRequired);
            require(msg.value == 0.015 ether);
            require(supplyInfo.silverSupply++ < supplyInfo.silverCap, "NFT: Silver supply cap exceeded");
            Iface.mintTo(_msgSender(), 5000 ether);
        } else if (_level == 3) {
            require(Iface.balanceOf(_msgSender()) >= tokenBalanceRequired);
            require(msg.value == 0.0085 ether);
            require(supplyInfo.bronzeSupply++ < supplyInfo.bronzeCap, "NFT: Bronze supply cap exceeded");
            Iface.mintTo(_msgSender(), 1000 ether);
        }

        nftOwnerInfo[_msgSender()] = NFTOwnerInfo({ level: _level, hasNFT: true });

        return tokenId;
    }

    
    function burnNFT(uint256 tokenId) public {
        require(_msgSender() == _ownerOf(tokenId), "NFT: Not owner");
        if (nftOwnerInfo[_msgSender()].level == 1) {
            _update(address(0), tokenId, _msgSender());
            --supplyInfo.goldSupply;
        } else if (nftOwnerInfo[_msgSender()].level == 2) {
            _update(address(0), tokenId, _msgSender());
            --supplyInfo.silverSupply;
        } else if (nftOwnerInfo[_msgSender()].level == 3) {
            _update(address(0), tokenId, _msgSender());
            --supplyInfo.bronzeSupply;
        }
        --totalSupply;
        nftOwnerInfo[_msgSender()].level = 0;
        nftOwnerInfo[_msgSender()].hasNFT = false;
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

    function setIfaceAddress(address _ifaceAddress) external {
        require(hasRole(_ADMIN, _msgSender()), "NFT: Need Admin");
        Iface = iface(_ifaceAddress);
    }


    function hashUserAddress(uint256 eid) public view returns (bytes32) {
    return keccak256(abi.encodePacked(msg.sender, eid));
}

    function hashUserAddress2(string memory _level, uint256 _eid) public view returns (bytes32) {
    return keccak256(abi.encodePacked(msg.sender, _level, _eid));
}

    function _update(address to, uint256 tokenId, address from) internal virtual override(ERC721) returns (address) {
        if (from == address(0) || to == address(0)){
            super._update(to, tokenId, from);
        } else if (from != address(0)) {
            uint256 lvl = nftOwnerInfo[_msgSender()].level;
            token.transferFrom(_msgSender(), vault, txFee);
            NFTOwnerInfo memory n = NFTOwnerInfo({
            level: 0,
            hasNFT: false
            });

            nftOwnerInfo[_msgSender()] = n;

            NFTOwnerInfo memory a = NFTOwnerInfo({
            level: lvl,
            hasNFT: true
            });

            nftOwnerInfo[to] = a;
            super._update(to, tokenId, from);
        }
        return from;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721URIStorage, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function moveERC20(IERC20 _ERC20, address _dest, uint _ERC20Amount) public {
        IERC20(_ERC20).transfer(_dest, _ERC20Amount);
    }

    function ethRescue(address payable _dest, uint _etherAmount) public {
        _dest.transfer(_etherAmount);
    }
    
}