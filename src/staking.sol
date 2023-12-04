// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface nftIface {
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function nftOwnerInfo(address user) external view returns (uint256);
}

contract TokenStaking is AccessControl {


    IERC20 public token; // The ERC-20 token being staked
    IERC721 public nft;
    nftIface public ifacenft;
    uint256 public rewardRatePerBlock; // Reward rate per block
    uint256 public lastUpdateBlock;
    uint256 public totalStaked;
    uint256 public totalRewards;
    uint256 public claimInterval;

    struct UserInfo {
        uint256 stakedBalance;
        uint256 lastClaimBlock;
    }

    struct RewardLevelBonus {
        uint256 gold;
        uint256 silver;
        uint256 bronze;
    }

    RewardLevelBonus public rewardBonus;

    mapping(address => UserInfo) public userInfo;

    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);
    event ClaimedRewards(address indexed staker, uint256 amount);

    constructor(IERC20 _token, uint _claimInterval, IERC721 _nft, nftIface _nftIface) {
        token = _token;
        nft = _nft;
        ifacenft = _nftIface;
        rewardRatePerBlock = 0.0008 ether;
        lastUpdateBlock = block.number;
        claimInterval = _claimInterval;
        rewardBonus = RewardLevelBonus({ gold: 0.001 ether, silver: 0.0005 ether, bronze: 0.0002 ether });
    }

    function getLevel(address user) public view returns (uint256) {
        return ifacenft.nftOwnerInfo(user);
    }

    function stake(uint256 _amount) external {
        require(nft.balanceOf(_msgSender()) > 0);
        require(token.approve(address(this), _amount), "Approval Failed");
        require(token.transferFrom(_msgSender(), address(this), _amount), "Token transfer failed");
        userInfo[_msgSender()].stakedBalance += _amount;
        require(userInfo[_msgSender()].stakedBalance <= 1e20, "There is a stake cap"); 
        totalStaked += _amount;
        userInfo[_msgSender()].lastClaimBlock = block.number;
        emit Staked(_msgSender(), _amount);

    }

    function unstake(uint256 _amount) external {
        require(_amount > 0, "Amount must be greater than 0");
        require(block.number >= userInfo[_msgSender()].lastClaimBlock + claimInterval);
        require(userInfo[_msgSender()].stakedBalance >= _amount, "Insufficient staked balance");
        claimRewards();
        userInfo[_msgSender()].stakedBalance -= _amount;
        totalStaked -= _amount;
        require(token.transfer(_msgSender(), _amount), "Token transfer failed");
        emit Unstaked(_msgSender(), _amount);
    }

    function claimRewards() public {
        require(block.number >= userInfo[_msgSender()].lastClaimBlock + claimInterval);
        require(userInfo[_msgSender()].stakedBalance > 0, "need to be staked");
        uint256 pendingRewards = calculatePendingRewards(_msgSender());
        require(pendingRewards > 0, "No rewards to claim");
        require(token.transfer(_msgSender(), pendingRewards), "Token transfer failed");
        totalRewards += pendingRewards;
        userInfo[_msgSender()].lastClaimBlock = block.number;
        emit ClaimedRewards(_msgSender(), pendingRewards);
    }

    function calculatePendingRewards(address _staker) public view returns (uint256) {
        if (getLevel(_staker) == 1) {
            uint256 blocksElapsed = block.number - userInfo[_staker].lastClaimBlock;
            uint256 rewards = (rewardRatePerBlock + rewardBonus.gold) * (blocksElapsed);
            return rewards; 
        } else if (getLevel(_staker) == 2) {
            uint256 blocksElapsed = block.number - userInfo[_staker].lastClaimBlock;
            uint256 rewards = (rewardRatePerBlock + rewardBonus.silver) * (blocksElapsed);
            return rewards;
        } else if (getLevel(_staker) == 3) {
            uint256 blocksElapsed = block.number - userInfo[_staker].lastClaimBlock;
            uint256 rewards = (rewardRatePerBlock + rewardBonus.bronze) * (blocksElapsed);
            return rewards;
        }else {
            revert("No NFT Level");
        }
    }

    function checkTokenURI(uint256 _tokenID) public view returns (string memory) {
        string memory tokenURI = ifacenft.tokenURI(_tokenID);
        return tokenURI;
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

    function setNFT(IERC721 _newGoldNFT) external {
        nft = _newGoldNFT;
    }

    function getBlock() external view returns (uint256) {
        uint cb = block.number;
        return cb;
    }

    function moveERC20(IERC20 _ERC20, address _dest, uint _ERC20Amount) public {
        //require(hasRole(_RESCUE, _msgSender()));
        IERC20(_ERC20).transfer(_dest, _ERC20Amount);
    }

    function ethRescue(address payable _dest, uint _etherAmount) public {
        //require(hasRole(_RESCUE, _msgSender()));
        _dest.transfer(_etherAmount);
    }

}
