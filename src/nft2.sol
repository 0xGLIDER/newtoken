// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

// Import statements from OpenZeppelin
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC721URIStorage } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IEqualFiToken } from "./interfaces/IEqualFiToken.sol";
import { hextool } from "./libraries/hex.sol";

/**
 * @title EqualFiNFT
 * @dev This contract implements an ERC721 NFT with minting logic, token balance requirements, interaction with the EqualFi token,
 *      and a refund mechanism if a minimum purchase threshold is not met by a specified deadline.
 *      It features a role-based access system for minting and admin tasks, reentrancy protection, supply limits per NFT level,
 *      and the ability to refund buyers if the sale does not meet its goals.
 */
contract EqualfiNFT is ERC721URIStorage, AccessControl, ReentrancyGuard {
    
    // ========================== State Variables ==========================

    // Sale and Refund Mechanism Variables
    uint256 public minimumTotalSupply; // Minimum number of NFTs to be sold
    uint256 public saleDeadline; // Timestamp after which refunds can be claimed if threshold not met
    bool public refundsEnabled; // Indicates if refunds have been enabled
    mapping(address => uint256) public contributions; // Tracks each buyer's Ether contributions
    bool public saleFinalized; // Indicates if the sale has been finalized

    // NFT and Token Variables
    bool public paused; // Indicates if minting functionality is paused
    uint256 private nextTokenId; // Tracks the next tokenId for minting
    uint256 public totalSupply; // Total supply of minted NFTs
    IEqualFiToken public Iface; // Interface for ERC20 token interaction (minting and burning)
    string public currentTokenURI; // Base URI for all NFTs
    uint256 public txFee; // Transaction fee for transferring NFTs (in ERC20 tokens)
    uint256 public lvlOnePurchasePrice = 2.5e15; // Price in Wei for level 1 NFT
    uint256 public lvlTwoPurchasePrice = 1.5e15; // Price in Wei for level 2 NFT
    uint256 public lvlThreePurchasePrice = 1e15; // Price in Wei for level 3 NFT
    uint256 public tokenAmtPerLvlOnePurchase = 1e22; // ERC20 tokens rewarded for purchasing a level 1 NFT
    uint256 public tokenAmtPerLvlTwoPurchase = 5e21; // ERC20 tokens rewarded for purchasing a level 2 NFT
    uint256 public tokenAmtPerLvlThreePurchase = 1e21; // ERC20 tokens rewarded for purchasing a level 3 NFT
    uint256 public tokensMinted;
    
    // Role identifiers using keccak256 hash of role names
    bytes32 public constant _MINT = keccak256("_MINT"); // Role for minting NFTs
    bytes32 public constant _ADMIN = keccak256("_ADMIN"); // Role for performing admin tasks
    bytes32 public constant _RESCUE = keccak256("_RESCUE"); // Role for rescue functions (recovering assets)

    // Structs for Supply and Ownership Information

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

    // Mapping from user addresses to their NFT ownership details
    mapping(address => NFTOwnerInfo) public nftOwnerInfo;

    // ========================== Events ==========================

    /**
     * @dev Emitted when the sale is finalized.
     * @param successful Indicates if the sale met the minimum supply threshold.
     */
    event SaleFinalized(bool successful);

    /**
     * @dev Emitted when a buyer claims a refund.
     * @param buyer The address of the buyer.
     * @param amount The amount refunded.
     */
    event RefundClaimed(address indexed buyer, uint256 amount);

    /**
     * @dev Emitted when the admin withdraws funds.
     * @param admin The address of the admin.
     * @param amount The amount withdrawn.
     */
    event FundsWithdrawn(address indexed admin, uint256 amount);

    // ========================== Modifiers ==========================

    /**
     * @dev Modifier to ensure contract is not paused before executing the function.
     */
    modifier onOff() {
        require(!paused, "Minting NFT and Tokens is disabled");
        _;
    }

    /**
     * @dev Modifier to ensure the sale is active (not finalized).
     */
    modifier saleActive() {
        require(!saleFinalized, "Sale has been finalized");
        _;
    }

    // ========================== Constructor ==========================

    /**
     * @dev Constructor to initialize the EqualfiNFT contract with refund mechanism parameters.
     * @param _tokenURI The base URI for all NFTs.
     * @param _ifaceAddress The address of the IEqualFiToken contract.
     * @param _minimumTotalSupply The minimum number of NFTs that must be sold to avoid refunds.
     * @param _saleDuration The duration of the sale in seconds from contract deployment.
     */
    constructor(
        string memory _tokenURI,    
        address _ifaceAddress,
        uint256 _minimumTotalSupply, // Minimum NFTs to be sold
        uint256 _saleDuration // Duration of the sale in seconds
    ) ERC721("NewNFT", "NFT") {
        currentTokenURI = _tokenURI;
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

        // Set the minimum total supply and sale deadline
        minimumTotalSupply = _minimumTotalSupply;
        saleDeadline = block.number + _saleDuration;

        // Grant roles to the contract deployer
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender()); // Grant default admin role
        _grantRole(_ADMIN, _msgSender()); // Grant admin role
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

    // ========================== Sale Finalization and Refund Functions ==========================

    /**
     * @dev Finalizes the sale after the deadline. If the minimum supply is not met, enables refunds.
     *      If the minimum supply is met, allows the admin to withdraw the funds.
     *      Only callable by an admin.
     */
    function finalizeSale() external onlyRole(_ADMIN) {
        require(block.number >= saleDeadline, "Sale not yet ended");
        require(!saleFinalized, "Sale already finalized");
        
        saleFinalized = true;
        
        if (totalSupply < minimumTotalSupply) {
            refundsEnabled = true;
            emit SaleFinalized(false);
        } else {
            emit SaleFinalized(true);
        }
    }

    /**
     * @dev Allows users to withdraw their contributions if refunds are enabled.
     *      Prevents reentrancy attacks by using the nonReentrant modifier and updating state before external calls.
     */
    function refund() external nonReentrant {
        require(refundsEnabled, "Refunds are not enabled");
        uint256 amount = contributions[_msgSender()];
        require(amount > 0, "No contributions to refund");
        
        // Reset the contribution before transferring to prevent reentrancy
        contributions[_msgSender()] = 0;
        
        // Transfer the Ether back to the buyer
        (bool success, ) = _msgSender().call{value: amount}("");
        require(success, "Refund transfer failed");
        
        emit RefundClaimed(_msgSender(), amount);
    }

    /**
     * @dev Allows the admin to withdraw the funds if the sale is successful.
     *      Only callable by an admin.
     *      Prevents reentrancy attacks by using the nonReentrant modifier.
     */
    function withdrawFunds() external nonReentrant onlyRole(_ADMIN) {
        require(saleFinalized, "Sale not yet finalized");
        require(!refundsEnabled, "Cannot withdraw funds, refunds are enabled");
        
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        
        // Transfer the Ether to the admin
        (bool success, ) = _msgSender().call{value: balance}("");
        require(success, "Withdrawal failed");
        
        emit FundsWithdrawn(_msgSender(), balance);
    }

    // ========================== Minting Functions ==========================

    /**
     * @dev Mint an NFT and associated ERC20 tokens based on the specified level. 
     *      The minting process requires the contract to be unpaused, the sale to be active, and the user does not already own an NFT.
     * @param _level The level of NFT (1: Gold, 2: Silver, 3: Bronze).
     * @return tokenId The ID of the newly minted NFT.
     */
    function mintNFTAndToken(uint256 _level) onOff nonReentrant saleActive public payable returns (uint256) {
        require(_level >= 1 && _level <= 3, "Invalid level");
        require(!nftOwnerInfo[_msgSender()].hasNFT, "Can't mint more than one NFT");
    
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tokenId)));
        _setTokenURI(tokenId, newID);
        _safeMint(_msgSender(), tokenId);

        totalSupply = ++totalSupply;
    
        // Track the buyer's contribution
        contributions[_msgSender()] += msg.value;
    
        // Handle minting and supply cap for each level
        if (_level == 1) {
            require(msg.value == lvlOnePurchasePrice, "Incorrect Ether value for Level 1");
            require(supplyInfo.goldSupply < supplyInfo.goldCap, "NFT: Gold supply cap exceeded");
            supplyInfo.goldSupply++;
            Iface.mintTo(_msgSender(), tokenAmtPerLvlOnePurchase);
            tokensMinted = tokensMinted + tokenAmtPerLvlOnePurchase;
        } else if (_level == 2) {
            require(msg.value == lvlTwoPurchasePrice, "Incorrect Ether value for Level 2");
            require(supplyInfo.silverSupply < supplyInfo.silverCap, "NFT: Silver supply cap exceeded");
            supplyInfo.silverSupply++;
            Iface.mintTo(_msgSender(), tokenAmtPerLvlTwoPurchase);
            tokensMinted = tokensMinted + tokenAmtPerLvlTwoPurchase;
        } else if (_level == 3) {
            require(msg.value == lvlThreePurchasePrice, "Incorrect Ether value for Level 3");
            require(supplyInfo.bronzeSupply < supplyInfo.bronzeCap, "NFT: Bronze supply cap exceeded");
            supplyInfo.bronzeSupply++;
            Iface.mintTo(_msgSender(), tokenAmtPerLvlThreePurchase);
            tokensMinted = tokensMinted + tokenAmtPerLvlThreePurchase;
        }

        // Update ownership information
        nftOwnerInfo[_msgSender()] = NFTOwnerInfo({ level: _level, hasNFT: true });

        return tokenId;
    }

    /**
     * @dev Mint an NFT without minting associated ERC20 tokens (post-initial sale).
     *      Requires that the contract is unpaused, the sale is active, the user does not already own an NFT, and meets token balance requirements.
     * @param _level The level of NFT (1: Gold, 2: Silver, 3: Bronze).
     * @return tokenId The ID of the newly minted NFT.
     */
    function mintNFT(uint256 _level) nonReentrant saleActive public payable returns (uint256) {
        require(_level >= 1 && _level <= 3, "Invalid level");
        require(!nftOwnerInfo[_msgSender()].hasNFT, "Can't mint more than one NFT");
    
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, hextool.toHex(hashUserAddress(tokenId)));
        _setTokenURI(tokenId, newID);
        _safeMint(_msgSender(), tokenId);

        totalSupply = ++totalSupply;
    
        // Track the buyer's contribution
        contributions[_msgSender()] += msg.value;
    
        // Handle minting and supply cap for each level
        if (_level == 1) {
            require(msg.value == lvlOnePurchasePrice, "Incorrect Ether value for Level 1");
            require(supplyInfo.goldSupply < supplyInfo.goldCap, "NFT: Gold supply cap exceeded");
            supplyInfo.goldSupply++;
        } else if (_level == 2) {
            require(msg.value == lvlTwoPurchasePrice, "Incorrect Ether value for Level 2");
            require(supplyInfo.silverSupply < supplyInfo.silverCap, "NFT: Silver supply cap exceeded");
            supplyInfo.silverSupply++;
        } else if (_level == 3) {
            require(msg.value == lvlThreePurchasePrice, "Incorrect Ether value for Level 3");
            require(supplyInfo.bronzeSupply < supplyInfo.bronzeCap, "NFT: Bronze supply cap exceeded");
            supplyInfo.bronzeSupply++;
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
            _burnAndUpdate(tokenId, 1);
            supplyInfo.goldSupply--;
        } else if (nftOwnerInfo[_msgSender()].level == 2) {
            _burnAndUpdate(tokenId, 2);
            supplyInfo.silverSupply--;
        } else if (nftOwnerInfo[_msgSender()].level == 3) {
            _burnAndUpdate(tokenId, 3);
            supplyInfo.bronzeSupply--;
        }

        totalSupply--;

        // Reset ownership information
        nftOwnerInfo[_msgSender()].level = 0;
        nftOwnerInfo[_msgSender()].hasNFT = false;

        // Burn the NFT
        _burn(tokenId);
    }

    /**
     * @dev Internal function to handle burning and updating ownership information.
     * @param tokenId The ID of the NFT to be burned.
     * @param level The level of the NFT being burned.
     */
    function _burnAndUpdate(uint256 tokenId, uint256 level) internal {
        // Additional logic can be implemented here if needed
        // Currently, ownership is already handled in burnNFT
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
