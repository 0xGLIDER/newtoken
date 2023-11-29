// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract TokenStaking is AccessControl {


    IERC20 public token; // The ERC-20 token being staked
    IERC721 public nft;
    uint256 public rewardRatePerBlock; // Reward rate per block
    uint256 public lastUpdateBlock;
    uint256 public totalStaked;
    uint256 public totalRewards;
    uint256 public claimInterval;

    struct UserInfo {
        uint256 stakedBalance;
        uint256 lastClaimBlock;
    }

    mapping(address => UserInfo) public userInfo;

    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);
    event ClaimedRewards(address indexed staker, uint256 amount);

    constructor(IERC20 _token, uint256 _rewardRatePerBlock, uint _claimInterval, IERC721 _nft) {
        token = _token;
        nft = _nft;
        rewardRatePerBlock = _rewardRatePerBlock;
        lastUpdateBlock = block.number;
        claimInterval = _claimInterval;
    }


    function stake(uint256 _amount) external {
        require(nft.balanceOf(msg.sender) > 0);
        require(_amount <= 1e20, "There is a Stake Cap");
        require(token.approve(address(this), _amount), "Approval Failed");
        require(token.transferFrom(msg.sender, address(this), _amount), "Token transfer failed");
        userInfo[msg.sender].stakedBalance += _amount;
        require(userInfo[msg.sender].stakedBalance <= 1e20, "There is a stake cap"); 
        totalStaked += _amount;
        userInfo[msg.sender].lastClaimBlock = block.number;
        emit Staked(msg.sender, _amount);

    }

    function unstake(uint256 _amount) external {
        require(_amount > 0, "Amount must be greater than 0");
        require(block.number >= userInfo[msg.sender].lastClaimBlock + claimInterval);
        require(userInfo[msg.sender].stakedBalance >= _amount, "Insufficient staked balance");
        claimRewards();
        userInfo[msg.sender].stakedBalance -= _amount;
        totalStaked -= _amount;
        require(token.transfer(msg.sender, _amount), "Token transfer failed");
        emit Unstaked(msg.sender, _amount);
    }

    function claimRewards() public {
        require(block.number >= userInfo[msg.sender].lastClaimBlock + claimInterval);
        require(userInfo[msg.sender].stakedBalance > 0, "need to be staked");
        uint256 pendingRewards = calculatePendingRewards(msg.sender);
        require(pendingRewards > 0, "No rewards to claim");
        require(token.transfer(msg.sender, pendingRewards), "Token transfer failed");
        totalRewards += pendingRewards;
        userInfo[msg.sender].lastClaimBlock = block.number;
        emit ClaimedRewards(msg.sender, pendingRewards);
    }

    function calculatePendingRewards(address _staker) public view returns (uint256) {
        if(userInfo[_staker].stakedBalance < 1e18) {
           uint256 rewards = 0; 
           return rewards;
        } else {
            uint256 blocksElapsed = block.number - userInfo[_staker].lastClaimBlock ;
            uint256 rewards = (rewardRatePerBlock * blocksElapsed);
            return rewards;
        }
    }

    function setRewardRatePerBlock(uint256 _newRewardRatePerBlock) external {
        require(_newRewardRatePerBlock >= 0, "Reward rate per block cannot be negative");
        rewardRatePerBlock = _newRewardRatePerBlock;
        lastUpdateBlock = block.number;
    }

    function setClaimInterval(uint256 _niw) external {
        claimInterval = _niw;
    }

    function setToken(IERC20 _newToken) external {
        token = _newToken;
    }

    function setNFT(IERC721 _newNFT) external {
        nft = _newNFT;
    }

    function getBlock() external view returns (uint256) {
        uint cb = block.number;
        return cb;
    }

    function moveERC20(IERC20 _ERC20, address _dest, uint _ERC20Amount) public {
        //require(hasRole(_RESCUE, msg.sender));
        IERC20(_ERC20).transfer(_dest, _ERC20Amount);
    }

    function ethRescue(address payable _dest, uint _etherAmount) public {
        //require(hasRole(_RESCUE, msg.sender));
        _dest.transfer(_etherAmount);
    }

}
