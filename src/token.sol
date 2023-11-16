// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract Token is ERC20, AccessControl {

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
   
    //------Token/Admin Constructor---------
    
    constructor() ERC20("Token", "TKN") {
        _cap = 1e26;
        mintDisabled = false;
        mintToDisabled = false;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        //-----Testing----

        _grantRole(_ADMIN, _msgSender());
        _grantRole(_MINT, _msgSender());
        _grantRole(_BURN, _msgSender());
    }
    

    //--------Toggle Functions----------------
    
    function setPaused(bool _paused) external {
        require(hasRole(_ADMIN, _msgSender()),"Contract: Need Admin");
        paused = _paused;
        if (_paused == true) {
            emit ContractPaused (block.number, _msgSender());
        } else if (_paused == false) {
            emit ContractUnpaused (block.number, _msgSender());
        }
    }
    
    function disableMint(bool _disableMinting) external {
        require(hasRole(_ADMIN, _msgSender()),"Contract: Need Admin");
        mintDisabled = _disableMinting;
        if (_disableMinting == true){
            emit MintingDisabled (block.number, _msgSender());
        }  else if (_disableMinting == false) {
            emit MintingEnabled (block.number, _msgSender());
        }  
    }
    
    function disableMintTo(bool _disableMintTo) external {
        require(hasRole(_ADMIN, _msgSender()),"Contract: Need Admin");
        mintToDisabled = _disableMintTo;
        if (_disableMintTo == true) {
            emit MintingToDisabled (block.number, _msgSender());
        } else if (_disableMintTo == false) {
            emit MintingToEnabled (block.number, _msgSender());
        }
    }

    //------Toggle Modifiers------------------
    
    modifier pause() {
        require(!paused, "Contract: Contract is Paused");
        _;
    }
    
    modifier mintDis() {
        require(!mintDisabled, "Contract: Minting is currently disabled");
        _;
    }
    
    modifier mintToDis() {
        require(!mintToDisabled, "Contract: Minting to addresses is curently disabled");
        _;
    }
    
    //------Token Functions-----------------
    
    function mintTo(address _to, uint _amount) external pause mintToDis{
        require(hasRole(_MINTTO, _msgSender()),"Contract: Need Minto");
        _mint(_to, _amount);
        emit TokensMintedTo(_to, _amount);
    }
    
    function mint( uint _amount) external pause mintDis{
        require(hasRole(_MINT, _msgSender()),"Contract: Need Mint");
        _mint(_msgSender(), _amount);
        emit TokensMinted(_amount);
    }
    
    function burn(uint _amount) external pause { 
        require(hasRole(_BURN, _msgSender()),"Contract: Need Burn");
        _burn(_msgSender(),  _amount);
        emit TokensBurned(_amount, _msgSender());
    }
    
    function burnFrom(address _from, uint _amount) external pause {
        require(hasRole(_BURNFROM, _msgSender()),"Contract: Need Burnfrom");
        _burn(_from, _amount);
        emit TokensBurnedFrom(_from, _amount, _msgSender());
    }


    //----------Supply Cap------------------
    
    function setSupplyCap(uint _supplyCap) external pause {
        require(hasRole(_SUPPLY, _msgSender()));
        require(_supplyCap >= totalSupply(), "Contract: Supply");
        require(totalSupply() <= _supplyCap, "Contract: Supply Cap");
        _cap = _supplyCap;
        emit SupplyCapChanged (_supplyCap, _msgSender());
    }
    
    function supplyCap() public view returns (uint) {
        return _cap;
    }
    

    function _update( address from, address to, uint256 amount) internal virtual override {
        super._update(from, to, amount);
        if (from == address(0)) { 
            require(totalSupply() <= _cap, "Contract: Supply Cap");
            emit Transfer(from, to, amount);
        }
    }


    //----------Rescue Functions------------

    function moveERC20(address _ERC20, address _dest, uint _ERC20Amount) public {
        require(hasRole(_RESCUE, msg.sender));
        IERC20(_ERC20).safeTransfer(_dest, _ERC20Amount);

    }

    function ethRescue(address payable _dest, uint _etherAmount) public {
        require(hasRole(_RESCUE, msg.sender));
        _dest.transfer(_etherAmount);
    }
    
}
