// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";


contract Token is ERC20, AccessControl, ReentrancyGuard {

    using SafeERC20 for IERC20;
    
   //------RBAC Vars--------------
   
    bytes32 public constant _MINT = keccak256("_MINT");
    bytes32 public constant _MINTTO = keccak256("_MINTTO");
    bytes32 public constant _BURN = keccak256("_BURN");
    bytes32 public constant _BURNFROM = keccak256("_BURNFROM");
    bytes32 public constant _SUPPLY = keccak256("_SUPPLY");
    bytes32 public constant _ADMIN = keccak256("_ADMIN");
    bytes32 public constant _RESCUE = keccak256("_RESCUE");
   
   //------Token Variables------------------
   
    uint private _cap;
    address public vault;
    uint public txFee = 0.005 ether;
    
    //-------Toggle Variables---------------
    
    bool public paused;
    bool public mintDisabled;
    bool public mintToDisabled;
    
    //----------Events-----------------------
    
    event TokensMinted (uint _amount);
    event TokensMintedTo (address _to, uint _amount);
    event TokensBurned (uint _amount, address _burner);
    event TokensBurnedFrom (address _from, uint _amount, address _burner);
    event SupplyCapChanged (uint _newCap, address _changedBy);
    event ContractPaused (uint _blockHeight, address _pausedBy);
    event ContractUnpaused (uint _blockHeight, address _unpausedBy);
    event MintingEnabled (uint _blockHeight, address _enabledBy);
    event MintingDisabled (uint _blockHeight, address _disabledBy);
    event MintingToEnabled (uint _blockHeight, address _enabledBy);
    event MintingToDisabled (uint _blockHeight, address _disabledBy);
    event ETHRescued (address _dest, uint _blockHeight, uint _amount);
    event ERC20Rescued (IERC20 _token, uint _blockHeight, address _dest, uint _amount);

    //------Mapping----------

    mapping(address => bool) public whitelistedAddress;
   
    //------Token/Admin Constructor---------
    
    constructor(address _vault) ERC20("Token", "TKN") {
        _cap = 10000000 ether;
        mintDisabled = false;
        mintToDisabled = false;
        vault = _vault;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        //-----Testing----

        _grantRole(_ADMIN, _msgSender());
        _grantRole(_MINT, _msgSender());
        _grantRole(_BURN, _msgSender());
        _mint(_msgSender(), 1000000 ether);
    }
    

    //--------Toggle Functions----------------
    
    function setPaused(bool _paused) external {
        require(hasRole(_ADMIN, _msgSender()), "Contract: Need Admin");
        paused = _paused;

        if (_paused) {
        emit ContractPaused(block.number, _msgSender());
        } else {
        emit ContractUnpaused(block.number, _msgSender());
        }
    }

    
    function disableMint(bool _disableMinting) external {
        require(hasRole(_ADMIN, _msgSender()), "Contract: Need Admin");
        mintDisabled = _disableMinting;

        if (_disableMinting) {
            emit MintingDisabled(block.number, _msgSender());
        } else {
            emit MintingEnabled(block.number, _msgSender());
        }
    }   

    
    function disableMintTo(bool _disableMintTo) external {
        require(hasRole(_ADMIN, _msgSender()), "Need Admin");
        mintToDisabled = _disableMintTo;

        if (_disableMintTo) {
            emit MintingToDisabled(block.number, _msgSender());
        } else {
            emit MintingToEnabled(block.number, _msgSender());
        }
    }


    //------Toggle Modifiers------------------
    
    modifier pause() {
        require(!paused, "Contract: Contract is Paused");
        _;
    }
    
    modifier mintDis() {
        require(!mintDisabled, "Minting disabled");
        _;
    }
    
    modifier mintToDis() {
        require(!mintToDisabled, "Minting to disabled");
        _;
    }
    
    //------Token Functions-----------------
    
    function mintTo(address _to, uint _amount) external pause mintToDis {
        require(hasRole(_MINTTO, _msgSender()), "Contract: Need Minto");
        require(totalSupply() + _amount <= _cap, "Contract: Supply Cap exceeded");
        emit TokensMintedTo(_to, _amount);
        _mint(_to, _amount);
}

    
    function mint( uint _amount) external pause mintDis{
        require(hasRole(_MINT, _msgSender()),"Contract: Need Mint");
        require(totalSupply() + _amount <= _cap, "Contract: Supply Cap exceeded");
        emit TokensMinted(
            _amount
        );
        _mint(_msgSender(), _amount);
    }
    
    function burn(uint _amount) external pause { 
        require(hasRole(_BURN, _msgSender()),"Contract: Need Burn");
        emit TokensBurned(
            _amount, _msgSender()
        );
        _burn(_msgSender(),  _amount);
    }
    
    function burnFrom(address _from, uint _amount) external pause {
        require(hasRole(_BURNFROM, _msgSender()),"Contract: Need Burnfrom");
        emit TokensBurnedFrom(
            _from, 
            _amount, 
            _msgSender()
        );
        _burn(_from, _amount);
    }


    //----------Supply Cap------------------
    
    function setSupplyCap(uint _supplyCap) external pause {
        require(hasRole(_SUPPLY, _msgSender()), "Need Supply");
        require(_supplyCap >= totalSupply(), "Contract: Supply");
        require(totalSupply() <= _supplyCap, "Contract: Supply Cap");
        _cap = _supplyCap;
        emit SupplyCapChanged (
            _supplyCap, 
            _msgSender()
        );
    }
    
    function supplyCap() public view returns (uint) {
        return _cap;
    }
    

    function _update(address from, address to, uint256 amount) internal virtual override {
        if (from == address(0)) { 
            require(totalSupply() + amount <= _cap, "Contract: Supply Cap exceeded");
        }
        super._update(from, to, amount);
    }


    //-----------Transfer--------------------

    function transferFrom(address from, address to, uint256 value) nonReentrant public virtual override returns (bool) {
        address spender = _msgSender();
        if(whitelistedAddress[spender]) {
            _transfer(from, to, value);
            //_spendAllowance(from, spender, value);
        }else{
            _transfer(from, to, value);
            _transfer(from, vault, txFee);
            //_spendAllowance(from, spender, value); 
        }
        return true;
    }

    function transfer(address to, uint256 value) nonReentrant public virtual override returns (bool) {
        address owner = _msgSender();
        if(whitelistedAddress[owner]) {
            _transfer(owner, to, value);
        }else {
            _transfer(owner, to, value);
            _transfer(owner, vault, txFee);
        }
 
        return true;
    }

    //---------Whitelist--------------------

    function setWhitelistAddress(address _whitelist, bool _status) external {
        require(hasRole(_ADMIN, msg.sender), "Need Admin");
        require(_whitelist != address(0), "No Zero address");
        whitelistedAddress[_whitelist] = _status;
    }

    //----------Rescue Functions------------

    function moveERC20(IERC20 _ERC20, address _dest, uint _ERC20Amount) nonReentrant public {
        require(hasRole(_RESCUE, msg.sender), "Need RESCUE");
        IERC20(_ERC20).safeTransfer(_dest, _ERC20Amount);
        emit ERC20Rescued(
            _ERC20, 
            block.number, 
            _dest, 
            _ERC20Amount
        );
    }

    function ethRescue(address payable _dest, uint _etherAmount) nonReentrant public {
        require(hasRole(_RESCUE, msg.sender), "Need RESCUE");
        _dest.transfer(_etherAmount);
        emit ETHRescued(
            _dest, 
            block.number, 
            _etherAmount
        );
    }
    
}
