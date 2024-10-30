// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC721URIStorage } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import { hextool } from "./hex.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title iface
 * @dev Interface for ERC20 token interactions including balance checks, minting, and burning.
 */
interface IEqualFiToken {
    /**
     * @dev Returns the ERC20 token balance of a specific account.
     * @param account The address to query the balance of.
     * @return The token balance of the specified account.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Mints a specified amount of tokens to a recipient.
     * @param recipient The address to receive the minted tokens.
     * @param amount The number of tokens to mint.
     */
    function mintTo(address recipient, uint256 amount) external;

    /**
     * @dev Burns a specified amount of tokens from a sender's account.
     * @param sender The address from which tokens will be burned.
     * @param amount The number of tokens to burn.
     */
    function burnFrom(address sender, uint256 amount) external;
}

/**
 * @title EqualFiNFT
 * @dev This contract implements an ERC721 NFT with minting logic, token balance requirements, and interaction with the EqualFi token.
 *      It features a role-based access system for minting and admin tasks, reentrancy protection, and supply limits per NFT level.
 */
contract EqualfiNFT is ERC721URIStorage, AccessControl, ReentrancyGuard {
    
    // ========================== State Variables ==========================

    bool public paused; // Indicates if minting functionality is paused
    uint256 private nextTokenId; // Tracks the next tokenId for minting
    uint256 public totalSupply; // Total supply of minted NFTs
    uint256 public tokenBalanceRequired; // ERC20 token balance required to mint an NFT
    IERC20 public token; // ERC20 token contract used for balance checks
    IEqualFiToken public Iface; // Interface for ERC20 token interaction (minting and burning)
    string public currentTokenURI; // Base URI for all NFTs
    uint256 public txFee; // Transaction fee for transferring NFTs (in ERC20 tokens)
    uint256 public lvlOnePurchasePrice = 2.5e15; // Price in Wei for level 1 NFT
    uint256 public lvlTwoPurchasePrice = 1.5e15; // Price in Wei for level 2 NFT
    uint256 public lvlThreePurchasePrice = 1e15; // Price in Wei for level 3 NFT
    uint256 public tokenAmtPerLvlOnePurchase = 1e22; // ERC20 tokens rewarded for purchasing a level 1 NFT
    uint256 public tokenAmtPerLvlTwoPurchase = 5e21; // ERC20 tokens rewarded for purchasing a level 2 NFT
    uint256 public tokenAmtPerLvlThreePurchase = 1e21; // ERC20 tokens rewarded for purchasing a level 3 NFT
    
    // Role identifiers using keccak256 hash of role names
    bytes32 public constant _MINT = keccak256("_MINT"); // Role for minting NFTs
    bytes32 public constant _ADMIN = keccak256("_ADMIN"); // Role for performing admin tasks
    bytes32 public constant _RESCUE = keccak256("_RESCUE"); // Role for rescue functions (recovering assets)

    // ========================== Structs ==========================

    /**
     * @dev Struct to manage the supply caps and current supply for each NFT level.
     */
    struct SupplyInfo {
        uint256 goldCap; // Maximum supply of Gold-level NFTs
        uint256 silverCap; // Maximum supply of Silver-level NFTs
        uint256 bronzeCap; // Maximum supply of Bronze-level NFTs
        uint256 goldSupply; // Current supply of Gold-level NFTs
        uint256 silverSupply; // Current supply of Silver-level NFTs
        uint256 bronzeSupply; // Current supply of Bronze-level NFTs
    }

    SupplyInfo public supplyInfo; // Tracks NFT level caps and supplies

    /**
     * @dev Struct to store information about NFT ownership and level.
     */
    struct NFTOwnerInfo {
        uint256 level; // Level of the owned NFT (1: Gold, 2: Silver, 3: Bronze)
        bool hasNFT; // Whether the user owns an NFT
    }

    // ========================== Mappings ==========================

    /**
     * @dev Mapping from user addresses to their NFT ownership details.
     */
    mapping(address => NFTOwnerInfo) public nftOwnerInfo;

    // ========================== Constructor ==========================

    /**
     * @dev Constructor to initialize the contract with a base URI, token contract, required token balance, and iface.
     *      Grants the deployer admin rights and sets the supply limits for each NFT level.
     * @param _tokenURI The base URI for NFTs.
     * @param _tokenContract The ERC20 token contract used for balance checks.
     * @param _setTokenBalanceRequired Minimum ERC20 token balance required for minting.
     * @param _ifaceAddress The address of the iface contract for minting and burning ERC20 tokens.
     */
    constructor(
        string memory _tokenURI, 
        IERC20 _tokenContract, 
        uint256 _setTokenBalanceRequired,  
        address _ifaceAddress
    ) ERC721("NewNFT", "NFT") {
        currentTokenURI = _tokenURI;
        token = _tokenContract;
        tokenBalanceRequired = _setTokenBalanceRequired;
        txFee = 1.5e19; // Set initial transaction fee for transfers
        Iface = IEqualFiToken(_ifaceAddress); // Set iface contract for ERC20 minting/burning

        // Initialize supply caps and set current supplies to zero
        supplyInfo = SupplyInfo({
            goldCap: 50, 
            silverCap: 100, 
            bronzeCap: 200, 
            goldSupply: 0, 
            silverSupply: 0, 
            bronzeSupply: 0
        });

        // Grant roles to the contract deployer
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender()); // Grant default admin role
        _grantRole(_ADMIN, _msgSender()); // Grant admin role
    }

    // ========================== Modifiers ==========================

    /**
     * @dev Modifier to ensure contract is not paused before executing the function.
     */
    modifier onOff() {
        require(!paused, "Minting NFT and Tokens is disabled");
        _;
    }

    // ========================== Admin Functions ==========================

    /**
     * @dev Function to pause or unpause the contract's minting functions. 
     *      Only callable by an admin.
     * @param _on Boolean indicating whether to pause (true) or unpause (false).
     */
    function setOn(bool _on) external onlyRole(_ADMIN) {
        paused = _on;
    }

    /**
     * @dev Sets a new base URI for the NFTs. Only callable by an admin.
     * @param newURI The new base URI.
     * @return The updated URI.
     */
    function setURI(string memory newURI) public onlyRole(_ADMIN) returns (string memory) {
        currentTokenURI = newURI;
        return currentTokenURI;
    } 

    /**
     * @dev Updates the required token balance for minting NFTs. Only callable by an admin.
     * @param rta The new required token balance.
     * @return The updated required token balance.
     */
    function setRequiredTokenAmount (uint256 rta) public onlyRole(_ADMIN) returns (uint256) {
        tokenBalanceRequired = rta;
        return rta;
    }

    /**
     * @dev Updates the transaction fee for transferring NFTs. Only callable by an admin.
     * @param _newFee The new transaction fee.
     */
    function setTxFee(uint256 _newFee) external onlyRole(_ADMIN) {
        txFee = _newFee;
    }

    /**
     * @dev Sets new supply caps for the Gold, Silver, and Bronze NFT levels. Only callable by an admin.
     * @param _newGS The new Gold supply cap.
     * @param _newSS The new Silver supply cap.
     * @param _newBS The new Bronze supply cap.
     */
    function setSupplyCaps(uint256 _newGS, uint256 _newSS, uint256 _newBS) public onlyRole(_ADMIN) {
        require(_newGS >= supplyInfo.goldSupply, "New Gold cap less than current supply");
        supplyInfo.goldCap = _newGS;

        require(_newSS >= supplyInfo.silverSupply, "New Silver cap less than current supply");
        supplyInfo.silverCap = _newSS;

        require(_newBS >= supplyInfo.bronzeSupply, "New Bronze cap less than current supply");
        supplyInfo.bronzeCap = _newBS;
    }

    /**
     * @dev Updates the iface contract for ERC20 interactions. Only callable by an admin.
     * @param _ifaceAddress The new iface contract address.
     */
    function setIfaceAddress(address _ifaceAddress) external onlyRole(_ADMIN) {
        Iface = IEqualFiToken(_ifaceAddress);
    }

    /**
     * @dev Updates the Ether prices for purchasing each level of NFT. Only callable by an admin.
     * @param _lvlOne The new price for level 1 NFTs.
     * @param _lvlTwo The new price for level 2 NFTs.
     * @param _lvlThree The new price for level 3 NFTs.
     */
    function setLvlPurchasePrices(uint256 _lvlOne, uint256 _lvlTwo, uint256 _lvlThree) external onlyRole(_ADMIN) {
        lvlOnePurchasePrice = _lvlOne;
        lvlTwoPurchasePrice = _lvlTwo;
        lvlThreePurchasePrice = _lvlThree;
    }

    /**
     * @dev Updates the ERC20 token amounts rewarded for purchasing each level of NFT. Only callable by an admin.
     * @param _lvlOne The new amount for level 1 NFTs.
     * @param _lvlTwo The new amount for level 2 NFTs.
     * @param _lvlThree The new amount for level 3 NFTs.
     */
    function setTknAmtPerLvl(uint256 _lvlOne, uint256 _lvlTwo, uint256 _lvlThree) external onlyRole(_ADMIN) {
        tokenAmtPerLvlOnePurchase = _lvlOne;
        tokenAmtPerLvlTwoPurchase = _lvlTwo;
        tokenAmtPerLvlThreePurchase = _lvlThree;      
    }

    // ========================== Minting Functions ==========================

    /**
     * @dev Mint an NFT and associated ERC20 tokens based on the specified level. 
     *      The minting process requires the contract to be unpaused and the user does not already own an NFT.
     * @param _level The level of NFT (1: Gold, 2: Silver, 3: Bronze).
     * @return tokenId The ID of the newly minted NFT.
     */
    function mintNFTAndToken(uint256 _level) onOff nonReentrant public payable returns (uint256) {
        require(_level >= 1 && _level <= 3, "Invalid level");
        require(!nftOwnerInfo[_msgSender()].hasNFT, "Can't mint more than one NFT");
    
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tokenId)));
        _setTokenURI(tokenId, newID);
        _safeMint(_msgSender(), tokenId);

        totalSupply = ++totalSupply;
    
        // Handle minting and supply cap for each level
        if (_level == 1) {
            require(msg.value == lvlOnePurchasePrice, "Incorrect Ether value for Level 1");
            require(supplyInfo.goldSupply++ < supplyInfo.goldCap, "NFT: Gold supply cap exceeded");
            Iface.mintTo(_msgSender(), tokenAmtPerLvlOnePurchase);
        } else if (_level == 2) {
            require(msg.value == lvlTwoPurchasePrice, "Incorrect Ether value for Level 2");
            require(supplyInfo.silverSupply++ < supplyInfo.silverCap, "NFT: Silver supply cap exceeded");
            Iface.mintTo(_msgSender(), tokenAmtPerLvlTwoPurchase);
        } else if (_level == 3) {
            require(msg.value == lvlThreePurchasePrice, "Incorrect Ether value for Level 3");
            require(supplyInfo.bronzeSupply++ < supplyInfo.bronzeCap, "NFT: Bronze supply cap exceeded");
            Iface.mintTo(_msgSender(), tokenAmtPerLvlThreePurchase);
        }

        // Update ownership information
        nftOwnerInfo[_msgSender()] = NFTOwnerInfo({ level: _level, hasNFT: true });

        return tokenId;
    }

    /**
     * @dev Mint an NFT without minting associated ERC20 tokens (post-initial sale).
     *      Requires that the contract is unpaused, the user does not already own an NFT, and meets token balance requirements.
     * @param _level The level of NFT (1: Gold, 2: Silver, 3: Bronze).
     * @return tokenId The ID of the newly minted NFT.
     */
    function mintNFT(uint256 _level) nonReentrant public payable returns (uint256) {
        require(_level >= 1 && _level <= 3, "Invalid level");
        require(!nftOwnerInfo[_msgSender()].hasNFT, "Can't mint more than one NFT");
    
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tokenId)));
        _setTokenURI(tokenId, newID);
        _safeMint(_msgSender(), tokenId);

        totalSupply = ++totalSupply;
    
        // Handle minting and supply cap for each level
        if (_level == 1) {
            require(Iface.balanceOf(_msgSender()) >= tokenBalanceRequired, "Insufficient token balance for Level 1");
            require(msg.value == lvlOnePurchasePrice, "Incorrect Ether value for Level 1");
            require(supplyInfo.goldSupply++ < supplyInfo.goldCap, "NFT: Gold supply cap exceeded");
        } else if (_level == 2) {
            require(Iface.balanceOf(_msgSender()) >= tokenBalanceRequired, "Insufficient token balance for Level 2");
            require(msg.value == lvlTwoPurchasePrice, "Incorrect Ether value for Level 2");
            require(supplyInfo.silverSupply++ < supplyInfo.silverCap, "NFT: Silver supply cap exceeded");
        } else if (_level == 3) {
            require(Iface.balanceOf(_msgSender()) >= tokenBalanceRequired, "Insufficient token balance for Level 3");
            require(msg.value == lvlThreePurchasePrice, "Incorrect Ether value for Level 3");
            require(supplyInfo.bronzeSupply++ < supplyInfo.bronzeCap, "NFT: Bronze supply cap exceeded");
        }

        // Update ownership information
        nftOwnerInfo[_msgSender()] = NFTOwnerInfo({ level: _level, hasNFT: true });

        return tokenId;
    }

    // ========================== Burning Functions ==========================

    /**
     * @dev Burns an NFT and updates the supply and ownership status accordingly.
     * @param tokenId The ID of the NFT to be burned.
     */
    function burnNFT(uint256 tokenId) nonReentrant public {
        require(_msgSender() == ownerOf(tokenId), "NFT: Caller is not the owner");

        // Determine the level of the NFT and update supply accordingly
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

        // Reset ownership information
        nftOwnerInfo[_msgSender()].level = 0;
        nftOwnerInfo[_msgSender()].hasNFT = false;

        // Burn the NFT
        _burn(tokenId);
    }

    // ========================== Utility Functions ==========================

    /**
     * @dev Allows NFT owners to update their token's URI.
     * @param tid The ID of the token whose URI is to be updated.
     * @return The updated URI.
     */
    function userUpdateURI(uint256 tid) public returns (string memory) {
        address owner = ownerOf(tid);
        require(_msgSender() == owner, "NFT: Caller is not the owner");
        string memory updatedURI = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tid)));
        _setTokenURI(tid, updatedURI);
        return updatedURI;
    }

    /**
     * @dev Hashes the user's address with the given tokenId for generating a unique URI.
     * @param eid The tokenId to hash.
     * @return The hashed result as a bytes32 value.
     */
    function hashUserAddress(uint256 eid) public view returns (bytes32) {
        return keccak256(abi.encodePacked(msg.sender, eid));
    }

    /**
     * @dev Hashes the user's address with the given token level and tokenId.
     * @param _level The level to hash with the address and tokenId.
     * @param _eid The tokenId to hash with the level and address.
     * @return The hashed result as a bytes32 value.
     */
    function hashUserAddress2(string memory _level, uint256 _eid) public view returns (bytes32) {
        return keccak256(abi.encodePacked(msg.sender, _level, _eid));
    }

    /**
     * @dev Returns the Ether balance of the contract.
     * @return The Ether balance in wei.
     */
    function getETHBalance() public view returns (uint256) {
        return address(this).balance;
    }

    // ========================== Internal Functions ==========================

    /**
     * @dev Internal function to update ownership information and apply the transaction fee if applicable.
     * @param to The address receiving the NFT.
     * @param tokenId The tokenId being transferred.
     * @param from The address transferring the NFT.
     * @return The new owner address after transfer.
     */
    function _update(address to, uint256 tokenId, address from) internal virtual override(ERC721) returns (address) {
        // Step 1: Update ownership information
        NFTOwnerInfo memory previousOwnerInfo;
        if (from != address(0)) {
            previousOwnerInfo = nftOwnerInfo[from];
            nftOwnerInfo[from] = NFTOwnerInfo({ level: 0, hasNFT: false });
        }

        if (to != address(0)) {
            nftOwnerInfo[to] = NFTOwnerInfo({ level: previousOwnerInfo.level, hasNFT: true });
        }

        // Step 2: Apply transaction fee if transferring between users
        if (from != address(0) && to != address(0)) {
            Iface.burnFrom(from, txFee);
        }

        // Step 3: Complete the transfer using the parent class's function
        return super._update(to, tokenId, from);
    }

    // ========================== Rescue Functions ==========================

    /**
     * @dev Rescue ERC20 tokens mistakenly sent to the contract.
     *      Only callable by an account with the _RESCUE role.
     * @param _ERC20 The address of the ERC20 token to rescue.
     * @param _dest The address to send the rescued tokens to.
     * @param _ERC20Amount The amount of tokens to rescue.
     */
    function moveERC20(IERC20 _ERC20, address _dest, uint _ERC20Amount) nonReentrant public onlyRole(_RESCUE) {
        require(_ERC20.transfer(_dest, _ERC20Amount), "ERC20: Transfer failed");
    }

    /**
     * @dev Rescue Ether mistakenly sent to the contract.
     *      Only callable by an account with the _RESCUE role.
     * @param _dest The address to send the rescued Ether to.
     * @param _etherAmount The amount of Ether to rescue.
     */
    function ethRescue(address payable _dest, uint _etherAmount) nonReentrant public onlyRole(_RESCUE) {
        require(address(this).balance >= _etherAmount, "Insufficient Ether balance");
        (bool success, ) = _dest.call{value: _etherAmount}("");
        require(success, "Ether transfer failed");
    }

    // ========================== Overrides ==========================

    /**
     * @dev Checks if the contract supports a given interface.
     * @param interfaceId The interface identifier.
     * @return True if supported, otherwise false.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721URIStorage, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
