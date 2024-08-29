// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {hextool} from "./hex.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface iface {
    function balanceOf(address account) external view returns (uint256);
    function mintTo(address recipient, uint256 amount) external;
}

/**
 * @title NFT
 * @dev This contract implements an ERC721 token with additional minting logic, token balance requirements,
 * and an interface for minting associated ERC20 tokens. It also includes pausing functionality, supply caps,
 * and ownership management with additional security features such as reentrancy protection and role-based access control.
 */
contract NFT is ERC721URIStorage, AccessControl, ReentrancyGuard {
    
    bool public paused; // Flag to pause the contract's minting functions
    uint256 private nextTokenId; // The ID for the next NFT to be minted
    uint256 public totalSupply; // Total number of NFTs minted
    uint256 public tokenBalanceRequired; // The minimum token balance required to mint an NFT
    IERC20 public token; // The ERC20 token required for minting NFTs
    iface public Iface; // Interface for interacting with the ERC20 contract
    string public currentTokenURI; // Base URI for all NFTs
    uint256 public txFee; // Fee in tokens for transferring NFTs
    address public vault; // Address where the transaction fees are sent
    bytes32 public constant _MINT = keccak256("_MINT"); // Role identifier for minting
    bytes32 public constant _ADMIN = keccak256("_ADMIN"); // Role identifier for admin functions

    // Structure to manage the supply caps and current supply of different NFT levels
    struct SupplyInfo {
        uint256 goldCap; // Maximum supply of Gold-level NFTs
        uint256 silverCap; // Maximum supply of Silver-level NFTs
        uint256 bronzeCap; // Maximum supply of Bronze-level NFTs
        uint256 goldSupply; // Current supply of Gold-level NFTs
        uint256 silverSupply; // Current supply of Silver-level NFTs
        uint256 bronzeSupply; // Current supply of Bronze-level NFTs
    }

    SupplyInfo public supplyInfo; // Instance of SupplyInfo

    // Structure to store information about NFT ownership and levels
    struct NFTOwnerInfo {
        uint256 level; // Level of the NFT owned by the user
        bool hasNFT; // Boolean indicating whether the user owns an NFT
    }

    // Mapping from user address to their NFT ownership information
    mapping(address => NFTOwnerInfo) public nftOwnerInfo;

    /**
     * @dev Constructor to initialize the NFT contract with the base URI, token contract, required token balance, vault address, and iface address.
     * @param _tokenURI The base URI for the NFTs.
     * @param _tokenContract The address of the required ERC20 token contract.
     * @param _setTokenBalanceRequired The minimum balance of tokens required to mint an NFT.
     * @param _setVault The address where transaction fees will be sent.
     * @param _ifaceAddress The address of the iface contract for minting ERC20 tokens.
     */
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
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /**
     * @dev Function to pause or unpause the minting functionality of the contract.
     * Only callable by an admin.
     * @param _paused Boolean indicating whether the contract should be paused.
     */
    function setPaused(bool _paused) external {
        require(hasRole(_ADMIN, _msgSender()), "Contract: Need Admin");
        paused = _paused;
    }

    /**
     * @dev Modifier to ensure that the contract is not paused before executing the function.
     */
    modifier pause() {
        require(!paused, "Minting NFT and Tokens is disabled");
        _;
    }

    //----------Minting Logic for initial sale.  Will Mint Tokens as well as NFT-------------------

    /**
     * @dev Public function to mint an NFT and associated ERC20 tokens based on the specified level.
     * Requires the contract to be unpaused and checks various conditions based on the level.
     * @param _level The level of the NFT to be minted (1 for Gold, 2 for Silver, 3 for Bronze).
     * @return The tokenId of the newly minted NFT.
     */
    function mintNFTAndToken (uint256 _level) pause nonReentrant public payable returns (uint256) {
        require(_level >= 1 && _level <= 3, "Invalid level");
        require(!nftOwnerInfo[_msgSender()].hasNFT, "Can't mint more than one NFT");
    
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tokenId)));
        _setTokenURI(tokenId, newID);
        _safeMint(_msgSender(), tokenId);

        totalSupply = ++totalSupply;
    
        // Update level-specific supply and check cap
        if (_level == 1) {
            require(msg.value == 0.025 ether, "Need Ether");
            require(supplyInfo.goldSupply++ < supplyInfo.goldCap, "NFT: Gold supply cap exceeded");
            Iface.mintTo(_msgSender(), 10000 ether);
        } else if (_level == 2) {
            require(msg.value == 0.015 ether);
            require(supplyInfo.silverSupply++ < supplyInfo.silverCap, "NFT: Silver supply cap exceeded");
            Iface.mintTo(_msgSender(), 5000 ether);
        } else if (_level == 3) {
            require(msg.value == 0.0085 ether);
            require(supplyInfo.bronzeSupply++ < supplyInfo.bronzeCap, "NFT: Bronze supply cap exceeded");
            Iface.mintTo(_msgSender(), 1000 ether);
        }

        nftOwnerInfo[_msgSender()] = NFTOwnerInfo({ level: _level, hasNFT: true });

        return tokenId;
    }

    //--------Minting Logic for the NFT after the initial token minting phase is over------------------------

    /**
     * @dev Public function to mint an NFT after the initial token minting phase is over.
     * No associated ERC20 tokens are minted in this function.
     * @param _level The level of the NFT to be minted (1 for Gold, 2 for Silver, 3 for Bronze).
     * @return The tokenId of the newly minted NFT.
     */
    function mintNFT (uint256 _level) nonReentrant public payable returns (uint256) {
        require(_level >= 1 && _level <= 3, "Invalid level");
        require(!nftOwnerInfo[_msgSender()].hasNFT, "Can't mint more than one NFT");
    
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tokenId)));
        _setTokenURI(tokenId, newID);
        _safeMint(_msgSender(), tokenId);

        totalSupply = ++totalSupply;
    
        // Update level-specific supply and check cap
        if (_level == 1) {
            require(Iface.balanceOf(_msgSender()) >= tokenBalanceRequired, "Token Balance");
            require(msg.value == 0.025 ether, "Need Ether");
            require(supplyInfo.goldSupply++ < supplyInfo.goldCap, "NFT: Gold supply cap exceeded");
        } else if (_level == 2) {
            require(Iface.balanceOf(_msgSender()) >= tokenBalanceRequired);
            require(msg.value == 0.015 ether);
            require(supplyInfo.silverSupply++ < supplyInfo.silverCap, "NFT: Silver supply cap exceeded");
        } else if (_level == 3) {
            require(Iface.balanceOf(_msgSender()) >= tokenBalanceRequired);
            require(msg.value == 0.0085 ether);
            require(supplyInfo.bronzeSupply++ < supplyInfo.bronzeCap, "NFT: Bronze supply cap exceeded");
        }

        nftOwnerInfo[_msgSender()] = NFTOwnerInfo({ level: _level, hasNFT: true });

        return tokenId;
    }

    //---------NFT Burning Logic----------------------

    /**
     * @dev Public function to burn an NFT. The corresponding supply is reduced, and the owner's NFT status is updated.
     * @param tokenId The ID of the NFT to be burned.
     */
    function burnNFT(uint256 tokenId) nonReentrant public {
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

    //----------Settable functions---------------------------

    /**
     * @dev Function to set a new base URI for the NFTs. Only callable by an admin.
     * @param newURI The new base URI to set.
     * @return The newly set base URI.
     */
    function setURI(string memory newURI) public returns (string memory) {
        require(hasRole(_ADMIN, _msgSender()), "NFT: Need Admin");
        currentTokenURI = newURI;
        return currentTokenURI;
    } 

    /**
     * @dev Function to update the URI of an existing NFT. Only the owner of the NFT can call this function.
     * @param tid The tokenId of the NFT to update.
     * @return The newly set URI.
     */
    function userUpdateURI (uint256 tid) public returns (string memory) {
        address owner = _ownerOf(tid);
        require(_msgSender() == owner, "NFT: Not owner");
        string memory i = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tid)));
        _setTokenURI(tid, i);
        return i;
    }

    /**
     * @dev Function to set the required token balance for minting NFTs. Only callable by an admin.
     * @param rta The new required token balance amount.
     * @return The newly set token balance requirement.
     */
    function setRequiredTokenAmount (uint256 rta) public returns (uint256) {
        require(hasRole(_ADMIN, _msgSender()), "NFT: Need Admin");
        tokenBalanceRequired = rta;
        return rta;
    }

    /**
     * @dev Function to set a new transaction fee for transferring NFTs.
     * @param _newFee The new transaction fee to set.
     */
    function setTxFee(uint256 _newFee) external {
        txFee = _newFee;
    }

    /**
     * @dev Function to set new supply caps for different NFT levels.
     * @param _newGS The new Gold-level supply cap.
     * @param _newSS The new Silver-level supply cap.
     * @param _newBS The new Bronze-level supply cap.
     */
    function setSupplyCaps(uint256 _newGS, uint256 _newSS, uint256 _newBS) public {
        supplyInfo.goldCap = _newGS;
        supplyInfo.silverCap = _newSS;
        supplyInfo.bronzeCap = _newBS;
    }

    /**
     * @dev Function to set a new iface contract address for minting ERC20 tokens. Only callable by an admin.
     * @param _ifaceAddress The new iface contract address.
     */
    function setIfaceAddress(address _ifaceAddress) external {
        require(hasRole(_ADMIN, _msgSender()), "NFT: Need Admin");
        Iface = iface(_ifaceAddress);
    }

    //--------------Hash functions---------------------------

    /**
     * @dev Function to hash the user's address with a tokenId. Used for generating unique URIs.
     * @param eid The tokenId to hash with the user's address.
     * @return The resulting hash as a bytes32 value.
     */
    function hashUserAddress(uint256 eid) public view returns (bytes32) {
        return keccak256(abi.encodePacked(msg.sender, eid));
    }

    /**
     * @dev Function to hash the user's address with a level and tokenId.
     * @param _level The level to hash with the user's address and tokenId.
     * @param _eid The tokenId to hash with the user's address and level.
     * @return The resulting hash as a bytes32 value.
     */
    function hashUserAddress2(string memory _level, uint256 _eid) public view returns (bytes32) {
        return keccak256(abi.encodePacked(msg.sender, _level, _eid));
    }

    //-------------Update Logic-------------------------------

    /**
     * @dev Internal function to update the ownership of an NFT, applying a transaction fee if necessary.
     * @param to The address receiving the NFT.
     * @param tokenId The tokenId of the NFT being transferred.
     * @param from The address sending the NFT.
     * @return The new owner of the tokenId.
     */
    function _update(address to, uint256 tokenId, address from) internal virtual override(ERC721) returns (address) {
        // Step 1: Perform all necessary state changes first.
        NFTOwnerInfo memory n;
        if (from != address(0)) {
            n = nftOwnerInfo[from];
            nftOwnerInfo[from] = NFTOwnerInfo({ level: 0, hasNFT: false });
        }

        if (to != address(0)) {
            nftOwnerInfo[to] = NFTOwnerInfo({ level: n.level, hasNFT: true });
        }

        // Step 2: Perform the token transfer fee after state changes.
        if (from != address(0) && to != address(0)) {
            token.transferFrom(from, vault, txFee);
        }

        // Step 3: Call the parent class's _update function.
        return super._update(to, tokenId, from);
    }

    //--------------Supports Interface and Rescue Functions-----------------

    /**
     * @dev Function to check if the contract supports a given interface.
     * @param interfaceId The interface identifier to check.
     * @return True if the interface is supported, otherwise false.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721URIStorage, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Function to rescue ERC20 tokens sent to the contract by mistake.
     * @param _ERC20 The address of the ERC20 token to rescue.
     * @param _dest The address to send the rescued tokens to.
     * @param _ERC20Amount The amount of tokens to rescue.
     */
    function moveERC20(IERC20 _ERC20, address _dest, uint _ERC20Amount) nonReentrant public {
        IERC20(_ERC20).transfer(_dest, _ERC20Amount);
    }

    /**
     * @dev Function to rescue Ether sent to the contract by mistake.
     * @param _dest The address to send the rescued Ether to.
     * @param _etherAmount The amount of Ether to rescue.
     */
    function ethRescue(address payable _dest, uint _etherAmount) nonReentrant public {
        _dest.transfer(_etherAmount);
    }

    function getETHBalance() public view returns (uint256) {
        return address(this).balance;
    }
    
}
