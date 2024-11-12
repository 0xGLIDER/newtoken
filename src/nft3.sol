// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

// OpenZeppelin Imports
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import { ONFT721Core } from "@layerzerolabs/ONFT721Core.sol";

// Custom Imports
import { IEqualFiToken } from "./interfaces/IEqualFiToken.sol";

// Uniswap V3 Interfaces
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address guy, uint wad) external returns (bool);
}

/**
 * @title EqualFiNFT
 * @dev ERC721 NFT Contract with Integrated Uniswap V3 Liquidity Provision
 */
contract EqualfiNFT is ERC721URIStorage, AccessControl, ReentrancyGuard {
    
    // ========================== State Variables ==========================
    
    // Sale and Refund Mechanism Variables
    uint256 public minimumTotalSupply; // Minimum number of NFTs to be sold
    uint256 public saleDeadlineBlock; // Block number after which sale is finalized
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
    uint256 public tokensMinted;
    
    // Uniswap V3 Integration Variables
    INonfungiblePositionManager public positionManager; // Uniswap V3 Position Manager
    IWETH9 public WETH; // WETH Contract
    uint24 public uniswapFeeTier; // Fee tier for Uniswap V3 pool (e.g., 3000 for 0.3%)
    int24 public tickLower; // Lower tick for Uniswap V3 position
    int24 public tickUpper; // Upper tick for Uniswap V3 position
    address public admin; // Admin address to receive liquidity position NFT

    // Role identifiers using keccak256 hash of role names
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

    struct NFTLevel {
        uint256 purchasePrice;      // Price in Wei to purchase the NFT
        uint256 tokenRewardAmount;  // ERC20 tokens rewarded upon purchase
    }

    mapping(uint8 => NFTLevel) public nftLevels;


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
     * @dev Emitted when liquidity is added to Uniswap V3.
     * @param tokenId The position NFT ID from Uniswap V3.
     * @param liquidity The amount of liquidity added.
     * @param amount0 The amount of token0 added.
     * @param amount1 The amount of token1 added.
     */
    event LiquidityAdded(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

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
     * @dev Constructor to initialize the EqualfiNFT contract with refund mechanism and Uniswap V3 integration.
     * @param _tokenURI The base URI for all NFTs.
     * @param _ifaceAddress The address of the EqualFiToken contract.
     * @param _minimumTotalSupply The minimum number of NFTs that must be sold to avoid refunds.
     * @param _saleBlocksDuration The number of blocks for the sale duration.
     * @param _positionManager The address of Uniswap V3's NonfungiblePositionManager.
     * @param _weth The address of the WETH9 contract.
     * @param _uniswapFeeTier The fee tier for the Uniswap V3 pool (e.g., 3000 for 0.3%).
     * @param _initialTickLower The lower tick boundary for the liquidity position.
     * @param _initialTickUpper The upper tick boundary for the liquidity position.
     */
    constructor(
        string memory _tokenURI,    
        address _ifaceAddress,
        uint256 _minimumTotalSupply, // Minimum NFTs to be sold
        uint256 _saleBlocksDuration, // Number of blocks for the sale duration
        address _positionManager, // Uniswap V3 Position Manager
        address _weth, // WETH9 Contract
        uint24 _uniswapFeeTier, // Uniswap V3 fee tier (e.g., 3000)
        int24 _initialTickLower, // Initial lower tick
        int24 _initialTickUpper // Initial upper tick
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

        // Set the minimum total supply and sale deadline based on block number
        minimumTotalSupply = _minimumTotalSupply;
        saleDeadlineBlock = block.number + _saleBlocksDuration;

        // Initialize Uniswap V3 Integration
        positionManager = INonfungiblePositionManager(_positionManager);
        WETH = IWETH9(_weth);
        uniswapFeeTier = _uniswapFeeTier;
        tickLower = _initialTickLower;
        tickUpper = _initialTickUpper;

        // Initialize Level 1
        nftLevels[1] = NFTLevel({
            purchasePrice: 2.5e15,
            tokenRewardAmount: 1e22
        });

        // Initialize Level 2
        nftLevels[2] = NFTLevel({
            purchasePrice: 1.5e15,
            tokenRewardAmount: 5e21
        });

        // Initialize Level 3
        nftLevels[3] = NFTLevel({
            purchasePrice: 1e15,
            tokenRewardAmount: 1e21
        });

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
     * @dev Updates the Uniswap V3 pool parameters. Only callable by an admin.
     * @param _positionManager The address of the Uniswap V3 Position Manager.
     * @param _weth The address of the WETH9 contract.
     * @param _feeTier The fee tier for the Uniswap V3 pool.
     * @param _tickLower The lower tick boundary for the liquidity position.
     * @param _tickUpper The upper tick boundary for the liquidity position.
     */
    function setUniswapParameters(
        address _positionManager,
        address _weth,
        uint24 _feeTier,
        int24 _tickLower,
        int24 _tickUpper
    ) external onlyRole(_ADMIN) {
        positionManager = INonfungiblePositionManager(_positionManager);
        WETH = IWETH9(_weth);
        uniswapFeeTier = _feeTier;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
    }

    // ========================== Sale Finalization and Refund Functions ==========================

    /**
     * @dev Finalizes the sale after the deadline. If the minimum supply is met, creates a Uniswap V3 liquidity pool.
     *      If the minimum supply is not met, enables refunds.
     *      Only callable by an admin.
     */
    function finalizeSale() external onlyRole(_ADMIN) nonReentrant {
        require(block.number >= saleDeadlineBlock, "Sale not yet ended");
        require(!saleFinalized, "Sale already finalized");
        
        saleFinalized = true;
        
        if (totalSupply < minimumTotalSupply) {
            refundsEnabled = true;
            emit SaleFinalized(false);
        } else {
            // Proceed to create Uniswap V3 liquidity pool
            _createUniswapV3Liquidity();
            emit SaleFinalized(true);
        }
    }

    /**
     * @dev Internal function to create Uniswap V3 liquidity pool using collected ETH and minted tokens.
     */
    function _createUniswapV3Liquidity() internal {
        uint256 ethAmount = address(this).balance;
        require(ethAmount > 0, "No ETH to add to liquidity");

        // Calculate the number of tokens to mint based on totalSupply
        // Assuming 1 token per NFT; adjust if different
        uint256 tokensToMint = totalSupply; // Adjust as per your logic
        require(tokensToMint > 0, "No tokens to mint");

        // Mint ERC20 tokens to the contract
        Iface.mintTo(address(this), tokensToMint);

        // Approve the Position Manager to spend ERC20 tokens
        Iface.approve(address(positionManager), tokensToMint);

        // Wrap ETH into WETH
        WETH.deposit{value: ethAmount}();

        // Approve the Position Manager to spend WETH
        WETH.approve(address(positionManager), ethAmount);

        // Define token0 and token1 based on addresses to maintain consistency
        address token0 = address(Iface) < address(WETH) ? address(Iface) : address(WETH);
        address token1 = address(Iface) < address(WETH) ? address(WETH) : address(Iface);

        // Define deadline (current block timestamp + buffer)
        uint256 deadline = block.timestamp + 300; // 5 minutes buffer

        // Create MintParams for Uniswap V3
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: uniswapFeeTier,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: token0 == address(Iface) ? tokensToMint : ethAmount,
            amount1Desired: token1 == address(Iface) ? tokensToMint : ethAmount,
            amount0Min: 0, // Set to 0 for simplicity; adjust as needed
            amount1Min: 0, // Set to 0 for simplicity; adjust as needed
            recipient: address(this),
            deadline: deadline
        });

        // Mint position
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = positionManager.mint(params);

        emit LiquidityAdded(tokenId, liquidity, amount0, amount1);

        // Transfer the liquidity position NFT to the admin
        positionManager.safeTransferFrom(address(this), admin, tokenId);
    }

    /**
     * @dev Allows users to withdraw their contributions if refunds are enabled.
     */
    function refund() external nonReentrant {
        require(refundsEnabled, "Refunds are not enabled");
        uint256 amount = contributions[msg.sender];
        require(amount > 0, "No contributions to refund");
        
        // Reset the contribution before transferring to prevent reentrancy
        contributions[msg.sender] = 0;
        
        // Transfer the Ether back to the buyer
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Refund transfer failed");
        
        emit RefundClaimed(msg.sender, amount);
    }

    // ========================== Minting Functions ==========================

    /**
     * @dev Mint an NFT and associated ERC20 tokens based on the specified level. 
     *      The minting process requires the contract to be unpaused, the sale to be active, and the user does not already own an NFT.
     * @param _level The level of NFT (1: Gold, 2: Silver, 3: Bronze).
     * @return tokenId The ID of the newly minted NFT.
     */
    function mintNFTAndToken(uint8 _level) onOff nonReentrant saleActive public payable returns (uint256) {
        require(_level >= 1 && _level <= 3, "Invalid level");
        //require(!nftOwnerInfo[msg.sender].hasNFT, "Can't mint more than one NFT");
        require(balanceOf(msg.sender) < 1, "You already own an NFT");

        NFTLevel memory levelData = nftLevels[_level];
        require(msg.value == levelData.purchasePrice, "Incorrect Ether value sent");

        require(getSupply(_level) < getSupplyCap(_level), "NFT: Supply cap exceeded for selected level");

        // Mint the NFT
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, addressToString(_msgSender()));
        _setTokenURI(tokenId, newID);
        _safeMint(msg.sender, tokenId);

        totalSupply++;

        // Track the buyer's contribution
        contributions[msg.sender] += msg.value;

        // Increment supply for the specific level
        incrementSupply(_level);

        // Mint ERC20 tokens to the buyer
        uint256 tokensToMint = levelData.tokenRewardAmount;
        Iface.mintTo(msg.sender, tokensToMint);
        tokensMinted = tokensMinted + tokensToMint;

        // Update ownership information
        nftOwnerInfo[msg.sender] = NFTOwnerInfo({ level: _level, hasNFT: true });

        return tokenId;
    }

    /**
     * @dev Mint an NFT without minting associated ERC20 tokens (post-initial sale).
     *      Requires that the contract is unpaused, the sale is active, the user does not already own an NFT, and meets token balance requirements.
     * @param _level The level of NFT (1: Gold, 2: Silver, 3: Bronze).
     * @return tokenId The ID of the newly minted NFT.
     */
    function mintNFT(uint8 _level) nonReentrant saleActive public payable returns (uint256) {
        require(_level >= 1 && _level <= 3, "Invalid level");
        require(!nftOwnerInfo[msg.sender].hasNFT, "Can't mint more than one NFT");
        //require(msg.value == getPurchasePrice(_level), "Incorrect Ether value for selected level");
        
        NFTLevel memory levelData = nftLevels[_level];
        require(msg.value == levelData.purchasePrice, "Incorrect Ether value sent");

        require(getSupply(_level) < getSupplyCap(_level), "NFT: Supply cap exceeded for selected level");

        // Mint the NFT
        uint256 tokenId = ++nextTokenId;
        string memory newID = string.concat(currentTokenURI, addressToString(_msgSender()));
        _setTokenURI(tokenId, newID);
        _safeMint(msg.sender, tokenId);

        totalSupply++;

        // Track the buyer's contribution
        contributions[msg.sender] += msg.value;

        // Increment supply for the specific level
        incrementSupply(_level);

        // Update ownership information
        nftOwnerInfo[msg.sender] = NFTOwnerInfo({ level: _level, hasNFT: true });

        return tokenId;
    }

    // ========================== Burning Functions ==========================

    /**
     * @dev Burns an NFT and updates the supply and ownership status accordingly.
     * @param tokenId The ID of the NFT to be burned.
     */
    function burnNFT(uint256 tokenId) nonReentrant public {
        require(msg.sender == ownerOf(tokenId), "NFT: Caller is not the owner");

        // Determine the level of the NFT and update supply accordingly
        uint256 level = nftOwnerInfo[msg.sender].level;
        require(level >=1 && level <=3, "Invalid NFT level");

        if (level == 1) {
            supplyInfo.goldSupply--;
        } else if (level == 2) {
            supplyInfo.silverSupply--;
        } else if (level == 3) {
            supplyInfo.bronzeSupply--;
        }

        totalSupply--;

        // Reset ownership information
        nftOwnerInfo[msg.sender].level = 0;
        nftOwnerInfo[msg.sender].hasNFT = false;

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
        require(msg.sender == owner, "NFT: Caller is not the owner");
        string memory updatedURI = string.concat(currentTokenURI, addressToString(_msgSender()));
        _setTokenURI(tid, updatedURI);
        return updatedURI;
    }

     function addressToString(address _addr) public pure returns (string memory) {
        return Strings.toHexString(uint160(_addr), 20);
    }

    /**
     * @dev Returns the Ether balance of the contract.
     * @return The Ether balance in wei.
     */
    function getETHBalance() public view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Retrieves the current supply of a specific NFT level.
     * @param _level The level of NFT (1: Gold, 2: Silver, 3: Bronze).
     * @return The current supply count.
     */
    function getSupply(uint256 _level) public view returns (uint256) {
        if (_level == 1) {
            return supplyInfo.goldSupply;
        } else if (_level == 2) {
            return supplyInfo.silverSupply;
        } else if (_level == 3) {
            return supplyInfo.bronzeSupply;
        } else {
            revert("Invalid NFT level");
        }
    }

    /**
     * @dev Retrieves the supply cap of a specific NFT level.
     * @param _level The level of NFT (1: Gold, 2: Silver, 3: Bronze).
     * @return The supply cap.
     */
    function getSupplyCap(uint256 _level) public view returns (uint256) {
        if (_level == 1) {
            return supplyInfo.goldCap;
        } else if (_level == 2) {
            return supplyInfo.silverCap;
        } else if (_level == 3) {
            return supplyInfo.bronzeCap;
        } else {
            revert("Invalid NFT level");
        }
    }

    /**
     * @dev Increments the supply of a specific NFT level.
     * @param _level The level of NFT (1: Gold, 2: Silver, 3: Bronze).
     */
    function incrementSupply(uint256 _level) internal {
        if (_level == 1) {
            supplyInfo.goldSupply++;
        } else if (_level == 2) {
            supplyInfo.silverSupply++;
        } else if (_level == 3) {
            supplyInfo.bronzeSupply++;
        } else {
            revert("Invalid NFT level");
        }
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

    /**
     * @dev Fallback function to receive Ether.
     */
    receive() external payable {}

    /**
     * @dev Fallback function to handle calls with data.
     */
    fallback() external payable {}
}