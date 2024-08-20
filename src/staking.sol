// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface nftIface {
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function nftOwnerInfo(address user) external view returns (uint256);
}

contract TokenStaking is AccessControl, ReentrancyGuard {


    IERC20 public token; // The ERC-20 token being staked
    IERC721 public nft;
    nftIface public ifacenft;
    uint256 public rewardRatePerBlock; // Reward rate per block
    uint256 public lastUpdateBlock;
    uint256 public totalStaked;
    uint256 public totalRewards;
    uint256 public claimInterval;

    bytes32 public constant _RESCUE = keccak256("_RESCUE");
    bytes32 public constant _ADMIN = keccak256("_ADMIN");

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

    function stake(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Staking: Amount must be greater than 0");
        require(nft.balanceOf(_msgSender()) > 0, "Staking: No NFT balance");

        require(token.approve(address(this), _amount), "Staking: Approval failed");
        require(token.transferFrom(_msgSender(), address(this), _amount), "Staking: Token transfer failed");

        // Retrieve user info from storage once
        UserInfo storage user = userInfo[_msgSender()];

        user.stakedBalance += _amount;
        require(user.stakedBalance <= 1e20, "Stake exceeds cap");

        totalStaked += _amount;
        user.lastClaimBlock = block.number;

        emit Staked(_msgSender(), _amount);
    }



    function unstake(uint256 _amount) external nonReentrant {
        UserInfo storage user = userInfo[_msgSender()];
        require(_amount > 0, "TokenStaking: Amount must be greater than 0");
        require(user.stakedBalance >= _amount, "TokenStaking: Insufficient staked balance");
        require(block.number >= user.lastClaimBlock + claimInterval, "TokenStaking: Claim interval not met");

        claimRewards();

        user.stakedBalance -= _amount;
        totalStaked -= _amount;

        require(token.transfer(_msgSender(), _amount), "TokenStaking: Unstake transfer failed");

        emit Unstaked(_msgSender(), _amount);
    }


    function claimRewards() public nonReentrant {
        UserInfo storage user = userInfo[_msgSender()];
        require(user.stakedBalance > 0, "TokenStaking: No staked balance");
        require(block.number >= user.lastClaimBlock + claimInterval, "TokenStaking: Claim interval not met");

        uint256 pendingRewards = calculatePendingRewards(_msgSender());
        require(pendingRewards > 0, "TokenStaking: No rewards to claim");

        user.lastClaimBlock = block.number;
        totalRewards += pendingRewards;

        require(token.transfer(_msgSender(), pendingRewards), "TokenStaking: Reward transfer failed");

        emit ClaimedRewards(_msgSender(), pendingRewards);
    }


    function calculatePendingRewards(address _staker) public view returns (uint256) {
        uint256 level = getLevel(_staker);
        uint256 rewardBonusLevel;

        if (level == 1) {
            rewardBonusLevel = rewardBonus.gold;
        } else if (level == 2) {
            rewardBonusLevel = rewardBonus.silver;
        } else if (level == 3) {
            rewardBonusLevel = rewardBonus.bronze;
        } else {
            revert("No NFT Level");
        }

        uint256 blocksElapsed = block.number - userInfo[_staker].lastClaimBlock;
        uint256 rewards = (rewardRatePerBlock + rewardBonusLevel) * blocksElapsed;
    
        return rewards;
    }


    function setRewardRatePerBlock(uint256 _newRewardRatePerBlock) external {
        require(_newRewardRatePerBlock > 0, "Reward rate must be positive");
        require(hasRole(_ADMIN, _msgSender()));
        require(_newRewardRatePerBlock >= 0, "Reward rate per block cannot be negative");
        rewardRatePerBlock = _newRewardRatePerBlock;
        lastUpdateBlock = block.number;
    }

    function setClaimInterval(uint256 _niw) external {
        require(hasRole(_ADMIN, _msgSender()));
        claimInterval = _niw;
    }

    function setToken(IERC20 _newToken) external {
        require(hasRole(_ADMIN, _msgSender()));
        token = _newToken;
    }

    function setNFT(IERC721 _newGoldNFT) external {
        require(hasRole(_ADMIN, _msgSender()));
        nft = _newGoldNFT;
    }

    function getBlock() external view returns (uint256) {
        uint cb = block.number;
        return cb;
    }

    function moveERC20(IERC20 _ERC20, address _dest, uint _ERC20Amount) nonReentrant public {
        require(hasRole(_RESCUE, _msgSender())); 
        IERC20(_ERC20).transfer(_dest, _ERC20Amount);
    }

    function ethRescue(address payable _dest, uint _etherAmount) nonReentrant public {
        require(hasRole(_RESCUE, _msgSender()));
        _dest.transfer(_etherAmount);
    }

}
