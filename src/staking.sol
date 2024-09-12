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

interface IMintableToken is IERC20 {
    function mintTo(address recipient, uint256 amount) external;
}

/**
 * @title TokenStaking
 * @dev This contract allows users to stake ERC20 tokens and claim rewards based on the staking duration.
 * It also supports NFT-based reward bonuses. The contract is protected against reentrancy attacks and
 * uses role-based access control for administrative functions.
 */
contract TokenStaking is AccessControl, ReentrancyGuard {

    IMintableToken public token; // The ERC-20 token being staked, with minting capability
    IERC721 public nft; // The NFT contract used to determine staking eligibility and bonuses
    nftIface public ifacenft; // Interface for retrieving NFT owner information
    uint256 public rewardRatePerBlock; // Reward rate per block for staking
    uint256 public lastUpdateBlock; // Block number of the last update to the reward rate
    uint256 public totalStaked; // Total amount of tokens staked in the contract
    uint256 public totalRewards; // Total amount of rewards distributed
    uint256 public claimInterval; // Number of blocks between reward claims
    uint256 public stakeCap = 1e21;

    // Role identifiers for different administrative actions
    bytes32 public constant _RESCUE = keccak256("_RESCUE");
    bytes32 public constant _ADMIN = keccak256("_ADMIN");
    bytes32 public constant _MINTER = keccak256("_MINTER");

    // Structure to hold user-specific staking information
    struct UserInfo {
        uint256 stakedBalance; // The amount of tokens staked by the user
        uint256 lastClaimBlock; // The block number of the user's last reward claim
    }

    // Structure to hold reward bonuses for different NFT levels
    struct RewardLevelBonus {
        uint256 gold;   // Bonus for Gold level NFT holders
        uint256 silver; // Bonus for Silver level NFT holders
        uint256 bronze; // Bonus for Bronze level NFT holders
    }

    RewardLevelBonus public rewardBonus; // Instance of the RewardLevelBonus struct

    // Mapping from user address to their staking information
    mapping(address => UserInfo) public userInfo;

    // Events to track staking, unstaking, and reward claims
    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);
    event ClaimedRewards(address indexed staker, uint256 amount);

    /**
     * @dev Constructor to initialize the staking contract with the token, claim interval, NFT, and NFT interface.
     * @param _token The address of the mintable ERC-20 token contract.
     * @param _claimInterval The interval (in blocks) between reward claims.
     * @param _nft The address of the ERC-721 NFT contract.
     * @param _ifacenft The address of the NFT interface contract.
     */
    constructor(IMintableToken _token, uint _claimInterval, IERC721 _nft, nftIface _ifacenft) {
        token = _token;
        nft = _nft;
        ifacenft = _ifacenft;
        rewardRatePerBlock = 0.0008 ether;
        lastUpdateBlock = block.number;
        claimInterval = _claimInterval;
        rewardBonus = RewardLevelBonus({ gold: 0.001 ether, silver: 0.0005 ether, bronze: 0.0002 ether });
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(_ADMIN, _msgSender());
    }

    /**
     * @dev Public function to stake tokens. The nonReentrant modifier ensures no reentrancy attack.
     * @param _amount The amount of tokens to stake.
     */
    function stake(uint256 _amount) external nonReentrant {
        _stake(_amount);
    }

    /**
     * @dev Public function to unstake tokens. The nonReentrant modifier ensures no reentrancy attack.
     * @param _amount The amount of tokens to unstake.
     */
    function unstake(uint256 _amount) external nonReentrant {
        _unstake(_amount);
    }

    /**
     * @dev Public function to claim staking rewards. The nonReentrant modifier ensures no reentrancy attack.
     */
    function claimRewards() public nonReentrant {
        _claimRewards(_msgSender());
    }

    /**
     * @dev Internal function to handle staking logic.
     * @param _amount The amount of tokens to stake.
     */
    function _stake(uint256 _amount) internal {
        require(_amount > 0, "Staking: Amount must be greater than 0");
        require(nft.balanceOf(_msgSender()) > 0, "Staking: No NFT balance");

        require(token.transferFrom(_msgSender(), address(this), _amount), "Staking: Token transfer failed");

        UserInfo storage user = userInfo[_msgSender()];

        user.stakedBalance += _amount;
        require(user.stakedBalance <= stakeCap, "Stake exceeds cap");

        totalStaked += _amount;
        user.lastClaimBlock = block.number;

        emit Staked(_msgSender(), _amount);
    }

    /**
     * @dev Internal function to handle unstaking logic.
     * @param _amount The amount of tokens to unstake.
     */
    function _unstake(uint256 _amount) internal {
        UserInfo storage user = userInfo[_msgSender()];
        require(_amount > 0, "TokenStaking: Amount must be greater than 0");
        require(user.stakedBalance >= _amount, "TokenStaking: Insufficient staked balance");
        require(block.number >= user.lastClaimBlock + claimInterval, "TokenStaking: Claim interval not met");

        _claimRewards(_msgSender());

        user.stakedBalance -= _amount;
        totalStaked -= _amount;

        require(token.transfer(_msgSender(), _amount), "TokenStaking: Unstake transfer failed");

        emit Unstaked(_msgSender(), _amount);
    }

    /**
     * @dev Internal function to handle reward claiming logic.
     * @param staker The address of the staker claiming rewards.
     */
    function _claimRewards(address staker) internal {
        UserInfo storage user = userInfo[staker];
        require(user.stakedBalance > 0, "TokenStaking: No staked balance");
        require(block.number >= user.lastClaimBlock + claimInterval, "TokenStaking: Claim interval not met");

        uint256 pendingRewards = calculatePendingRewards(staker);
        require(pendingRewards > 0, "TokenStaking: No rewards to claim");

        user.lastClaimBlock = block.number;
        totalRewards += pendingRewards;

        token.mintTo(staker, pendingRewards);

        emit ClaimedRewards(staker, pendingRewards);
    }

    /**
     * @dev Calculates the pending rewards for a staker based on their staking duration and NFT level.
     * @param _staker The address of the staker.
     * @return The amount of pending rewards.
     */
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

    /**
     * @dev Gets the NFT level of a user.
     * @param user The address of the user.
     * @return The NFT level of the user.
     */
    function getLevel(address user) public view returns (uint256) {
        return ifacenft.nftOwnerInfo(user);
    }

    /**
     * @dev Sets a new reward rate per block. Only callable by an admin.
     * @param _newRewardRatePerBlock The new reward rate per block.
     */
    function setRewardRatePerBlock(uint256 _newRewardRatePerBlock) external onlyRole(_ADMIN) {
        require(_newRewardRatePerBlock > 0, "Reward rate must be positive");
        rewardRatePerBlock = _newRewardRatePerBlock;
        lastUpdateBlock = block.number;
    }

    /**
     * @dev Sets a new claim interval. Only callable by an admin.
     * @param _niw The new claim interval in blocks.
     */
    function setClaimInterval(uint256 _niw) external onlyRole(_ADMIN) {
        claimInterval = _niw;
    }

    /**
     * @dev Sets a new token contract for staking. Only callable by an admin.
     * @param _newToken The address of the new mintable token contract.
     */
    function setToken(IMintableToken _newToken) external onlyRole(_ADMIN){
        token = _newToken;
    }

    /**
     * @dev Sets a new NFT contract. Only callable by an admin.
     * @param _newNFT The address of the new ERC-721 NFT contract.
     */
    function setNFT(IERC721 _newNFT) external onlyRole(_ADMIN) {
        nft = _newNFT;
    }

    function setStakeCap(uint256 _newCap) external onlyRole(_ADMIN){
        stakeCap = _newCap;
    }

    /**
     * @dev Returns the current block number.
     * @return The current block number.
     */
    function getBlock() external view returns (uint256) {
        uint cb = block.number;
        return cb;
    }

    /**
     * @dev Allows an authorized user to rescue ERC20 tokens sent to the contract by mistake.
     * Only callable by a user with the RESCUE role.
     * @param _ERC20 The address of the ERC20 token to rescue.
     * @param _dest The address to send the rescued tokens to.
     * @param _ERC20Amount The amount of tokens to rescue.
     */
    function moveERC20(IERC20 _ERC20, address _dest, uint _ERC20Amount) nonReentrant public onlyRole(_RESCUE) {
        IERC20(_ERC20).transfer(_dest, _ERC20Amount);
    }

    /**
     * @dev Allows an authorized user to rescue Ether sent to the contract by mistake.
     * Only callable by a user with the RESCUE role.
     * @param _dest The address to send the rescued Ether to.
     * @param _etherAmount The amount of Ether to rescue.
     */
    function ethRescue(address payable _dest, uint _etherAmount) nonReentrant public onlyRole(_RESCUE){
        _dest.transfer(_etherAmount);
    }
}

