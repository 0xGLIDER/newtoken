// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title EqualFiToken
 * @dev This contract implements an ERC20 token with additional features such as minting, burning, pausing, 
 *      supply capping, and transfer fee mechanisms. It uses role-based access control for administrative functions 
 *      and is protected against reentrancy attacks.
 */
contract EqualFiToken is ERC20, AccessControl, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ========================== Roles ==========================

    /// @notice Role identifier for minting new tokens
    bytes32 public constant _MINT = keccak256("_MINT");

    /// @notice Role identifier for minting tokens to specific addresses
    bytes32 public constant _MINTTO = keccak256("_MINTTO");

    /// @notice Role identifier for burning tokens
    bytes32 public constant _BURN = keccak256("_BURN");

    /// @notice Role identifier for burning tokens from specific addresses
    bytes32 public constant _BURNFROM = keccak256("_BURNFROM");

    /// @notice Role identifier for modifying the supply cap
    bytes32 public constant _SUPPLY = keccak256("_SUPPLY");

    /// @notice Role identifier for administrative tasks
    bytes32 public constant _ADMIN = keccak256("_ADMIN");

    /// @notice Role identifier for rescuing tokens and Ether
    bytes32 public constant _RESCUE = keccak256("_RESCUE");
   
    // ========================== State Variables ==========================

    /// @notice Maximum supply cap for the token
    uint public _cap;

    /// @notice Transaction fee for transfers (0.005 tokens, assuming 18 decimals)
    uint public txFee = 5e15;

    /// @notice Flag to pause the contract's operations
    bool public paused;

    /// @notice Flag to disable minting
    bool public mintDisabled;

    /// @notice Flag to disable minting to specific addresses
    bool public mintToDisabled;
    
    // ========================== Events ==========================

    /// @notice Emitted when tokens are minted
    event TokensMinted(uint _amount);

    /// @notice Emitted when tokens are minted to a specific address
    event TokensMintedTo(address _to, uint _amount);

    /// @notice Emitted when tokens are burned from the caller's balance
    event TokensBurned(uint _amount, address _burner);

    /// @notice Emitted when tokens are burned from a specific address
    event TokensBurnedFrom(address _from, uint _amount, address _burner);

    /// @notice Emitted when the supply cap is changed
    event SupplyCapChanged(uint _newCap, address _changedBy);

    /// @notice Emitted when the contract is paused
    event ContractPaused(uint _blockHeight, address _pausedBy);

    /// @notice Emitted when the contract is unpaused
    event ContractUnpaused(uint _blockHeight, address _unpausedBy);

    /// @notice Emitted when minting is enabled
    event MintingEnabled(uint _blockHeight, address _enabledBy);

    /// @notice Emitted when minting is disabled
    event MintingDisabled(uint _blockHeight, address _disabledBy);

    /// @notice Emitted when minting to specific addresses is enabled
    event MintingToEnabled(uint _blockHeight, address _enabledBy);

    /// @notice Emitted when minting to specific addresses is disabled
    event MintingToDisabled(uint _blockHeight, address _disabledBy);

    /// @notice Emitted when Ether is rescued from the contract
    event ETHRescued(address _dest, uint _blockHeight, uint _amount);

    /// @notice Emitted when ERC20 tokens are rescued from the contract
    event ERC20Rescued(IERC20 _token, uint _blockHeight, address _dest, uint _amount);

    // ========================== Mappings ==========================

    /// @notice Mapping to track addresses exempt from transfer fees
    mapping(address => bool) public whitelistedAddress;

    // ========================== Constructor ==========================

    /**
     * @dev Constructor that sets the token name, symbol, and initial minting.
     *      It also grants necessary roles to the deployer and sets initial parameters such as the supply cap.
     */
    constructor() ERC20("Token", "TKN") {
        _cap = 1e25; // Set the supply cap to 10 million tokens (10^7 * 10^18 = 1e25 wei)
        mintDisabled = false; // Initially enable minting
        mintToDisabled = false; // Initially enable minting to specific addresses
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        // Grant initial roles to the deployer
        _grantRole(_ADMIN, _msgSender());
        _grantRole(_MINT, _msgSender());
        _grantRole(_BURN, _msgSender());

        // Mint 1 million tokens to the deployer for initial use (1e6 * 10^18 = 1e24 wei)
        _mint(_msgSender(), 1e24);
    }
    
    // ========================== Modifiers ==========================

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
    
    // ========================== Admin Functions ==========================

    /**
     * @dev Function to pause or unpause the contract's operations. 
     *      Only callable by an admin.
     * @param _paused Boolean indicating whether the contract should be paused (true) or unpaused (false).
     */
    function setPaused(bool _paused) external onlyRole(_ADMIN) {
        paused = _paused;

        if (_paused) {
            emit ContractPaused(block.number, _msgSender());
        } else {
            emit ContractUnpaused(block.number, _msgSender());
        }
    }

    /**
     * @dev Function to disable or enable minting.
     *      Only callable by an admin.
     * @param _disableMinting Boolean indicating whether minting should be disabled (true) or enabled (false).
     */
    function disableMint(bool _disableMinting) external onlyRole(_ADMIN) {
        mintDisabled = _disableMinting;

        if (_disableMinting) {
            emit MintingDisabled(block.number, _msgSender());
        } else {
            emit MintingEnabled(block.number, _msgSender());
        }
    }   

    /**
     * @dev Function to disable or enable minting to specific addresses.
     *      Only callable by an admin.
     * @param _disableMintTo Boolean indicating whether minting to specific addresses should be disabled (true) or enabled (false).
     */
    function disableMintTo(bool _disableMintTo) external onlyRole(_ADMIN) {
        mintToDisabled = _disableMintTo;

        if (_disableMintTo) {
            emit MintingToDisabled(block.number, _msgSender());
        } else {
            emit MintingToEnabled(block.number, _msgSender());
        }
    }

    /**
     * @dev Function to change the supply cap of the token.
     *      Only callable by an admin.
     * @param _supplyCap The new supply cap.
     */
    function setSupplyCap(uint _supplyCap) external pause onlyRole(_SUPPLY) {
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
     * @dev Function to add or remove an address from the whitelist. Whitelisted addresses are exempt from transfer fees.
     *      Only callable by an admin.
     * @param _whitelist The address to whitelist or remove from the whitelist.
     * @param _status Boolean indicating whether to add (true) or remove (false) the address from the whitelist.
     */
    function setWhitelistAddress(address _whitelist, bool _status) external onlyRole(_ADMIN) {
        require(_whitelist != address(0), "Invalid address");
        whitelistedAddress[_whitelist] = _status;
    }

    /**
     * @dev Function to update the transaction fee for transfers.
     *      Only callable by an admin.
     * @param _newFee The new transaction fee.
     */
    function setTxFee(uint256 _newFee) external onlyRole(_ADMIN) {
        txFee = _newFee;
    }

    // ========================== Minting Functions ==========================

    /**
     * @dev Function to mint tokens to a specific address.
     *      Only callable by an address with the _MINTTO role, and if minting to is enabled and contract is not paused.
     * @param _to The address to mint tokens to.
     * @param _amount The amount of tokens to mint.
     */
    function mintTo(address _to, uint _amount) external pause mintToDis onlyRole(_MINTTO) {
        require(totalSupply() + _amount <= _cap, "Contract: Supply Cap exceeded");
        emit TokensMintedTo(_to, _amount);
        _mint(_to, _amount);
    }

    /**
     * @dev Function to mint tokens to the caller.
     *      Only callable by an address with the _MINT role, and if minting is enabled and contract is not paused.
     * @param _amount The amount of tokens to mint.
     */
    function mint(uint _amount) external pause mintDis onlyRole(_MINT) {
        require(totalSupply() + _amount <= _cap, "Contract: Supply Cap exceeded");
        emit TokensMinted(_amount);
        _mint(_msgSender(), _amount);
    }
    
    // ========================== Burning Functions ==========================

    /**
     * @dev Function to burn tokens from the caller's balance.
     *      Only callable by an address with the _BURN role, and if the contract is not paused.
     * @param _amount The amount of tokens to burn.
     */
    function burn(uint _amount) external pause onlyRole(_BURN) { 
        emit TokensBurned(_amount, _msgSender());
        _burn(_msgSender(), _amount);
    }

    /**
     * @dev Function to burn tokens from a specific address.
     *      Only callable by an address with the _BURNFROM role, and if the contract is not paused.
     * @param _from The address to burn tokens from.
     * @param _amount The amount of tokens to burn.
     */
    function burnFrom(address _from, uint _amount) external pause onlyRole(_BURNFROM) {
        emit TokensBurnedFrom(_from, _amount, _msgSender());
        _burn(_from, _amount);
    }

    // ========================== Transfer Functions ==========================

    /**
     * @dev Overrides the `transferFrom` function to apply a transaction fee unless the sender is whitelisted.
     *      The transfer will reduce the spender's allowance if applicable.
     * @param from The address sending tokens.
     * @param to The address receiving tokens.
     * @param value The amount of tokens to transfer.
     * @return True if the transfer was successful.
     */
    function transferFrom(address from, address to, uint256 value) nonReentrant public virtual override returns (bool) {
        address spender = _msgSender();
        uint256 currentAllowance = allowance(from, spender);
        require(currentAllowance >= value, "ERC20: transfer amount exceeds allowance");

        // Decrease the allowance by the value being transferred
        _approve(from, spender, currentAllowance - value);

        if (whitelistedAddress[spender] == true) {
            _transfer(from, to, value);
        } else {
            // Transfer value to the recipient
            _transfer(from, to, value);

            // Apply transaction fee and burn it
            _burn(from, txFee);
        }

        return true;
    }

    /**
     * @dev Overrides the `transfer` function to apply a transaction fee unless the sender is whitelisted.
     * @param to The address receiving tokens.
     * @param value The amount of tokens to transfer.
     * @return True if the transfer was successful.
     */
    function transfer(address to, uint256 value) nonReentrant public virtual override returns (bool) {
        address owner = _msgSender();

        if (whitelistedAddress[owner]) {
            _transfer(owner, to, value);
        } else {
            // Transfer tokens and apply the fee
            _transfer(owner, to, value);
            _burn(owner, txFee);  // Apply transaction fee and burn it
        }

        return true;
    }

    // ========================== Rescue Functions ==========================

    /**
     * @dev Function to rescue ERC20 tokens sent to the contract by mistake.
     *      Only callable by an account with the _RESCUE role.
     * @param _ERC20 The ERC20 token contract to rescue.
     * @param _dest The address to send the rescued tokens to.
     * @param _ERC20Amount The amount of tokens to rescue.
     */
    function moveERC20(IERC20 _ERC20, address _dest, uint _ERC20Amount) nonReentrant public onlyRole(_RESCUE) {
        IERC20(_ERC20).safeTransfer(_dest, _ERC20Amount);
        emit ERC20Rescued(_ERC20, block.number, _dest, _ERC20Amount);
    }

    /**
     * @dev Function to rescue Ether sent to the contract by mistake.
     *      Only callable by an account with the _RESCUE role.
     * @param _dest The address to send the rescued Ether to.
     * @param _etherAmount The amount of Ether to rescue (in wei).
     */
    function ethRescue(address payable _dest, uint _etherAmount) nonReentrant public onlyRole(_RESCUE) {
        _dest.transfer(_etherAmount);
        emit ETHRescued(_dest, block.number, _etherAmount);
    }
    
}
