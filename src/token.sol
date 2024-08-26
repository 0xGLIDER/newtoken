// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title Token
 * @dev This contract implements an ERC20 token with additional features such as minting, burning, pausing, supply capping,
 * and transfer fee mechanisms. It uses role-based access control for administrative functions and is protected against reentrancy attacks.
 */
contract Token is ERC20, AccessControl, ReentrancyGuard {

    using SafeERC20 for IERC20;
    
    // Role identifiers for different administrative actions
    bytes32 public constant _MINT = keccak256("_MINT");
    bytes32 public constant _MINTTO = keccak256("_MINTTO");
    bytes32 public constant _BURN = keccak256("_BURN");
    bytes32 public constant _BURNFROM = keccak256("_BURNFROM");
    bytes32 public constant _SUPPLY = keccak256("_SUPPLY");
    bytes32 public constant _ADMIN = keccak256("_ADMIN");
    bytes32 public constant _RESCUE = keccak256("_RESCUE");
   
    uint private _cap; // Maximum supply cap for the token
    address public vault; // Address where transaction fees are sent
    uint public txFee = 5e15; // Transaction fee for transfers (0.005 ether in wei)
    
    bool public paused; // Flag to pause the contract's operations
    bool public mintDisabled; // Flag to disable minting
    bool public mintToDisabled; // Flag to disable minting to specific addresses
    
    // Events for logging important contract actions
    event TokensMinted(uint _amount);
    event TokensMintedTo(address _to, uint _amount);
    event TokensBurned(uint _amount, address _burner);
    event TokensBurnedFrom(address _from, uint _amount, address _burner);
    event SupplyCapChanged(uint _newCap, address _changedBy);
    event ContractPaused(uint _blockHeight, address _pausedBy);
    event ContractUnpaused(uint _blockHeight, address _unpausedBy);
    event MintingEnabled(uint _blockHeight, address _enabledBy);
    event MintingDisabled(uint _blockHeight, address _disabledBy);
    event MintingToEnabled(uint _blockHeight, address _enabledBy);
    event MintingToDisabled(uint _blockHeight, address _disabledBy);
    event ETHRescued(address _dest, uint _blockHeight, uint _amount);
    event ERC20Rescued(IERC20 _token, uint _blockHeight, address _dest, uint _amount);

    mapping(address => bool) public whitelistedAddress; // Mapping to track addresses that are exempt from transfer fees
   
    /**
     * @dev Constructor to initialize the token contract with a vault address and an initial supply of tokens.
     * @param _vault The address where transaction fees will be sent.
     */
    constructor(address _vault) ERC20("Token", "TKN") {
        _cap = 1e25; // Set the supply cap to 10 million tokens (10^7 * 10^18 = 1e25 wei)
        mintDisabled = false; // Initially enable minting
        mintToDisabled = false; // Initially enable minting to specific addresses
        vault = _vault;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        // Grant initial roles and mint an initial supply of tokens for testing
        _grantRole(_ADMIN, _msgSender());
        _grantRole(_MINT, _msgSender());
        _grantRole(_BURN, _msgSender());
        _mint(_msgSender(), 1e24); // Mint 1 million tokens to the deployer (1e6 * 10^18 = 1e24 wei)
    }
    
    /**
     * @dev Function to pause or unpause the contract's operations.
     * Only callable by an admin.
     * @param _paused Boolean indicating whether the contract should be paused.
     */
    function setPaused(bool _paused) external {
        require(hasRole(_ADMIN, _msgSender()), "Contract: Need Admin");
        paused = _paused;

        if (_paused) {
            emit ContractPaused(block.number, _msgSender());
        } else {
            emit ContractUnpaused(block.number, _msgSender());
        }
    }

    /**
     * @dev Function to disable or enable minting.
     * Only callable by an admin.
     * @param _disableMinting Boolean indicating whether minting should be disabled.
     */
    function disableMint(bool _disableMinting) external {
        require(hasRole(_ADMIN, _msgSender()), "Contract: Need Admin");
        mintDisabled = _disableMinting;

        if (_disableMinting) {
            emit MintingDisabled(block.number, _msgSender());
        } else {
            emit MintingEnabled(block.number, _msgSender());
        }
    }   

    /**
     * @dev Function to disable or enable minting to specific addresses.
     * Only callable by an admin.
     * @param _disableMintTo Boolean indicating whether minting to specific addresses should be disabled.
     */
    function disableMintTo(bool _disableMintTo) external {
        require(hasRole(_ADMIN, _msgSender()), "Need Admin");
        mintToDisabled = _disableMintTo;

        if (_disableMintTo) {
            emit MintingToDisabled(block.number, _msgSender());
        } else {
            emit MintingToEnabled(block.number, _msgSender());
        }
    }
    
    /**
     * @dev Modifier to ensure that the contract is not paused before executing the function.
     */
    modifier pause() {
        require(!paused, "Contract: Contract is Paused");
        _;
    }
    
    /**
     * @dev Modifier to ensure that minting is not disabled before executing the function.
     */
    modifier mintDis() {
        require(!mintDisabled, "Minting disabled");
        _;
    }
    
    /**
     * @dev Modifier to ensure that minting to specific addresses is not disabled before executing the function.
     */
    modifier mintToDis() {
        require(!mintToDisabled, "Minting to disabled");
        _;
    }
    
    /**
     * @dev Function to mint tokens to a specific address.
     * Only callable by an address with the _MINTTO role, and if minting to is enabled and contract is not paused.
     * @param _to The address to mint tokens to.
     * @param _amount The amount of tokens to mint.
     */
    function mintTo(address _to, uint _amount) external pause mintToDis {
        require(hasRole(_MINTTO, _msgSender()), "Contract: Need Minto");
        require(totalSupply() + _amount <= _cap, "Contract: Supply Cap exceeded");
        emit TokensMintedTo(_to, _amount);
        _mint(_to, _amount);
    }

    /**
     * @dev Function to mint tokens to the caller.
     * Only callable by an address with the _MINT role, and if minting is enabled and contract is not paused.
     * @param _amount The amount of tokens to mint.
     */
    function mint(uint _amount) external pause mintDis {
        require(hasRole(_MINT, _msgSender()), "Contract: Need Mint");
        require(totalSupply() + _amount <= _cap, "Contract: Supply Cap exceeded");
        emit TokensMinted(_amount);
        _mint(_msgSender(), _amount);
    }
    
    /**
     * @dev Function to burn tokens from the caller's balance.
     * Only callable by an address with the _BURN role, and if the contract is not paused.
     * @param _amount The amount of tokens to burn.
     */
    function burn(uint _amount) external pause { 
        require(hasRole(_BURN, _msgSender()), "Contract: Need Burn");
        emit TokensBurned(_amount, _msgSender());
        _burn(_msgSender(), _amount);
    }
    
    /**
     * @dev Function to burn tokens from a specific address.
     * Only callable by an address with the _BURNFROM role, and if the contract is not paused.
     * @param _from The address to burn tokens from.
     * @param _amount The amount of tokens to burn.
     */
    function burnFrom(address _from, uint _amount) external pause {
        require(hasRole(_BURNFROM, _msgSender()), "Contract: Need Burnfrom");
        emit TokensBurnedFrom(_from, _amount, _msgSender());
        _burn(_from, _amount);
    }
    
    /**
     * @dev Function to change the supply cap of the token.
     * Only callable by an address with the _SUPPLY role, and if the contract is not paused.
     * @param _supplyCap The new supply cap.
     */
    function setSupplyCap(uint _supplyCap) external pause {
        require(hasRole(_SUPPLY, _msgSender()), "Need Supply");
        require(_supplyCap >= totalSupply(), "Contract: Supply Cap too low");
        _cap = _supplyCap;
        emit SupplyCapChanged(_supplyCap, _msgSender());
    }
    
    /**
     * @dev Function to get the current supply cap.
     * @return The current supply cap.
     */
    function supplyCap() public view returns (uint) {
        return _cap;
    }
    
    /**
     * @dev Internal function to update the token balances, ensuring the supply cap is not exceeded.
     * @param from The address sending tokens.
     * @param to The address receiving tokens.
     * @param amount The amount of tokens being transferred.
     */
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (from == address(0)) { 
            require(totalSupply() + amount <= _cap, "Contract: Supply Cap exceeded");
        }
        super._update(from, to, amount);
    }

    /**
     * @dev Function to transfer tokens from one address to another, applying a transaction fee unless the sender is whitelisted.
     * @param from The address sending tokens.
     * @param to The address receiving tokens.
     * @param value The amount of tokens to transfer.
     * @return True if the transfer was successful.
     */
    function transferFrom(address from, address to, uint256 value) nonReentrant public virtual override returns (bool) {
        address spender = _msgSender();
        if (whitelistedAddress[spender]) {
            _transfer(from, to, value);
        } else {
            _transfer(from, to, value);
            _transfer(from, vault, txFee);
        }
        return true;
    }

    /**
     * @dev Function to transfer tokens from the caller's address to another, applying a transaction fee unless the sender is whitelisted.
     * @param to The address receiving tokens.
     * @param value The amount of tokens to transfer.
     * @return True if the transfer was successful.
     */
    function transfer(address to, uint256 value) nonReentrant public virtual override returns (bool) {
        address owner = _msgSender();
        if (whitelistedAddress[owner]) {
            _transfer(owner, to, value);
        } else {
            _transfer(owner, to, value);
            _transfer(owner, vault, txFee);
        }
        return true;
    }

    /**
     * @dev Function to add or remove an address from the whitelist.
     * Whitelisted addresses are exempt from transfer fees.
     * Only callable by an admin.
     * @param _whitelist The address to whitelist or remove from the whitelist.
     * @param _status Boolean indicating whether to add (true) or remove (false) the address from the whitelist.
     */
    function setWhitelistAddress(address _whitelist, bool _status) external {
        require(hasRole(_ADMIN, msg.sender), "Need Admin");
        require(_whitelist != address(0), "Invalid address");
        whitelistedAddress[_whitelist] = _status;
    }

    /**
     * @dev Function to rescue ERC20 tokens sent to the contract by mistake.
     * Only callable by an address with the _RESCUE role.
     * @param _ERC20 The address of the ERC20 token to rescue.
     * @param _dest The address to send the rescued tokens to.
     * @param _ERC20Amount The amount of tokens to rescue.
     */
    function moveERC20(IERC20 _ERC20, address _dest, uint _ERC20Amount) nonReentrant public {
        require(hasRole(_RESCUE, msg.sender), "Need RESCUE");
        IERC20(_ERC20).safeTransfer(_dest, _ERC20Amount);
        emit ERC20Rescued(_ERC20, block.number, _dest, _ERC20Amount);
    }

    /**
     * @dev Function to rescue Ether sent to the contract by mistake.
     * Only callable by an address with the _RESCUE role.
     * @param _dest The address to send the rescued Ether to.
     * @param _etherAmount The amount of Ether to rescue.
     */
    function ethRescue(address payable _dest, uint _etherAmount) nonReentrant public {
        require(hasRole(_RESCUE, msg.sender), "Need RESCUE");
        _dest.transfer(_etherAmount);
        emit ETHRescued(_dest, block.number, _etherAmount);
    }
    
}
