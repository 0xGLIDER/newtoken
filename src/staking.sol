// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IEqualFiToken } from "./interfaces/IEqualFiToken.sol";
import { IEqualFiNFT } from "./interfaces/IEqualFiNFT.sol";


/**
 * @title equalfiStaking
 * @dev This contract allows users to stake ERC20 tokens and claim rewards based on their staking duration.
 *      It also supports NFT-based reward bonuses. The contract is protected against reentrancy attacks and uses
 *      role-based access control for administrative functions.
 */
contract equalfiStaking is AccessControl, ReentrancyGuard {

    // ========================== State Variables ==========================

    IEqualFiToken public token; // ERC20 token contract used for staking, with minting capabilities
    IERC721 public nft; // ERC721 NFT contract for determining staking bonuses
    IEqualFiNFT public ifacenft; // Interface for retrieving NFT owner and metadata information
    uint256 public rewardRatePerBlock; // Reward rate for each block the user stakes tokens
    uint256 public lastUpdateBlock; // Block number of the last update to the reward rate
    uint256 public totalStaked; // Total amount of tokens staked in the contract
    uint256 public totalRewards; // Total amount of rewards distributed so far
    uint256 public claimInterval; // Number of blocks between reward claims
    uint256 public stakeCap = 1e21; // Maximum amount a user can stake

    // ========================== Roles ==========================

    /// @notice Role identifier for rescuing funds mistakenly sent to the contract
    bytes32 public constant _RESCUE = keccak256("_RESCUE");

    /// @notice Admin role for managing contract settings
    bytes32 public constant _ADMIN = keccak256("_ADMIN");

    /// @notice Role for minting rewards to users
    bytes32 public constant _MINTER = keccak256("_MINTER");

    // ========================== Structures ==========================

    /**
     * @dev Structure to store individual user staking information.
     */
    struct UserInfo {
        uint256 stakedBalance; // Amount of tokens staked by the user
        uint256 lastClaimBlock; // Block number when the user last claimed rewards
    }

    /**
     * @dev Structure to hold bonus reward percentages for different NFT levels.
     */
    struct RewardLevelBonus {
        uint256 gold;   // Bonus percentage for Gold-level NFT holders
        uint256 silver; // Bonus percentage for Silver-level NFT holders
        uint256 bronze; // Bonus percentage for Bronze-level NFT holders
    }

    RewardLevelBonus public rewardBonus; // Instance to track bonus rewards for different NFT levels

    // ========================== Mappings ==========================

    /// @notice Mapping from user address to their staking information
    mapping(address => UserInfo) public userInfo;

    // ========================== Events ==========================

    /// @notice Emitted when a user stakes tokens
    event Staked(address indexed staker, uint256 amount);

    /// @notice Emitted when a user unstakes tokens
    event Unstaked(address indexed staker, uint256 amount);

    /// @notice Emitted when a user claims rewards
    event ClaimedRewards(address indexed staker, uint256 amount);

    // ========================== Constructor ==========================

    /**
     * @dev Constructor to initialize the staking contract with the token, claim interval, NFT contract, and NFT interface.
     *      Grants the deployer the admin roles.
     * @param _token The address of the ERC20 token contract with minting capabilities.
     * @param _claimInterval The number of blocks between reward claims.
     * @param _nft The address of the ERC721 NFT contract.
     * @param _IEqualFiNFT The address of the NFT interface for retrieving NFT details.
     */
    constructor(IEqualFiToken _token, uint _claimInterval, IERC721 _nft, IEqualFiNFT _IEqualFiNFT) {
        token = _token;
        nft = _nft;
        ifacenft = _IEqualFiNFT;
        rewardRatePerBlock = 8e14; // Set initial reward rate per block
        lastUpdateBlock = block.number;
        claimInterval = _claimInterval; // Set initial claim interval
        rewardBonus = RewardLevelBonus({ gold: 1e15, silver: 5e14, bronze: 2e14 }); // Set reward bonuses for different NFT levels
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender()); // Grant the deployer the default admin role
        _grantRole(_ADMIN, _msgSender()); // Grant the deployer the admin role
    }

    // ========================== Public Functions ==========================

    /**
     * @dev Public function to stake tokens. The amount to stake is specified as an argument.
     *      The nonReentrant modifier ensures that reentrancy attacks are prevented.
     * @param _amount The amount of tokens to stake.
     */
    function stake(uint256 _amount) external nonReentrant {
        _stake(_amount);
    }

    /**
     * @dev Public function to unstake tokens. The amount to unstake is specified as an argument.
     *      The nonReentrant modifier ensures that reentrancy attacks are prevented.
     * @param _amount The amount of tokens to unstake.
     */
    function unstake(uint256 _amount) external nonReentrant {
        _unstake(_amount);
    }

    /**
     * @dev Public function to claim rewards. The nonReentrant modifier ensures that reentrancy attacks are prevented.
     */
    function claimRewards() public nonReentrant {
        _claimRewards(_msgSender());
    }

    /**
     * @dev Public function to calculate the pending rewards for a staker.
     * @param _staker The address of the staker.
     * @return The calculated pending rewards.
     */
    function calculatePendingRewards(address _staker) public view returns (uint256) {
        uint256 level = getLevel(_staker);
        uint256 rewardBonusLevel;

        // Determine reward bonus based on NFT level
        if (level == 1) {
            rewardBonusLevel = rewardBonus.gold;
        } else if (level == 2) {
            rewardBonusLevel = rewardBonus.silver;
        } else if (level == 3) {
            rewardBonusLevel = rewardBonus.bronze;
        } else {
            revert("No NFT Level");
        }

        // Get the user's staked balance and calculate the number of blocks elapsed since last claim
        UserInfo storage user = userInfo[_staker];
        uint256 stakedAmount = user.stakedBalance;
        uint256 blocksElapsed = block.number - user.lastClaimBlock;

        // Calculate rewards based on staked amount, reward rate, and NFT level bonus
        uint256 rewards = (rewardRatePerBlock + rewardBonusLevel) * blocksElapsed * stakedAmount / 1e18;

        return rewards;
    }

    /**
     * @dev Public function to get the current block number.
     * @return The current block number.
     */
    function getBlock() external view returns (uint256) {
        return block.number;
    }

    /**
     * @dev Public function to get the NFT level of a user based on their holdings.
     * @param user The address of the user.
     * @return The NFT level of the user.
     */
    function getLevel(address user) public view returns (uint256) {
        return ifacenft.nftOwnerInfo(user);
    }

    // ========================== Internal Functions ==========================

    /**
     * @dev Internal function to handle staking logic.
     *      The user must own an NFT and have a positive staking amount.
     * @param _amount The amount of tokens to stake.
     */
    function _stake(uint256 _amount) internal {
        require(_amount > 0, "Staking: Amount must be greater than 0");
        require(nft.balanceOf(_msgSender()) > 0, "Staking: No NFT balance");

        // Transfer tokens from the user to the staking contract
        require(token.transferFrom(_msgSender(), address(this), _amount), "Staking: Token transfer failed");

        UserInfo storage user = userInfo[_msgSender()];
        user.stakedBalance += _amount; // Update the user's staked balance
        require(user.stakedBalance <= stakeCap, "Stake exceeds cap"); // Ensure the staked amount doesn't exceed the cap

        totalStaked += _amount; // Increase the total staked amount in the contract
        user.lastClaimBlock = block.number; // Update the block number of the last claim

        emit Staked(_msgSender(), _amount); // Emit the Staked event
    }

    /**
     * @dev Internal function to handle unstaking logic.
     *      The user must have enough staked tokens and meet the claim interval requirement.
     * @param _amount The amount of tokens to unstake.
     */
    function _unstake(uint256 _amount) internal {
        UserInfo storage user = userInfo[_msgSender()];
        require(_amount > 0, "TokenStaking: Amount must be greater than 0");
        require(user.stakedBalance >= _amount, "TokenStaking: Insufficient staked balance");
        require(block.number >= user.lastClaimBlock + claimInterval, "TokenStaking: Claim interval not met");

        _claimRewards(_msgSender()); // Claim pending rewards before unstaking

        user.stakedBalance -= _amount; // Reduce user's staked balance
        totalStaked -= _amount; // Reduce total staked amount in the contract

        // Transfer tokens back to the user
        require(token.transfer(_msgSender(), _amount), "TokenStaking: Unstake transfer failed");

        emit Unstaked(_msgSender(), _amount); // Emit the Unstaked event
    }

    /**
     * @dev Internal function to handle reward claiming logic.
     *      The user must meet the claim interval and have pending rewards.
     * @param staker The address of the staker claiming rewards.
     */
    function _claimRewards(address staker) internal {
        UserInfo storage user = userInfo[staker];
        require(user.stakedBalance > 0, "TokenStaking: No staked balance");
        require(block.number >= user.lastClaimBlock + claimInterval, "TokenStaking: Claim interval not met");

        uint256 pendingRewards = calculatePendingRewards(staker);
        require(pendingRewards > 0, "TokenStaking: No rewards to claim");

        user.lastClaimBlock = block.number; // Update user's last claim block
        totalRewards += pendingRewards; // Increase total rewards distributed

        token.mintTo(staker, pendingRewards); // Mint new tokens as rewards

        emit ClaimedRewards(staker, pendingRewards); // Emit the ClaimedRewards event
    }

    // ========================== Admin Functions ==========================

    /**
     * @dev Admin function to set a new reward rate per block.
     *      Only callable by an account with the _ADMIN role.
     * @param _newRewardRatePerBlock The new reward rate per block.
     */
    function setRewardRatePerBlock(uint256 _newRewardRatePerBlock) external onlyRole(_ADMIN) {
        require(_newRewardRatePerBlock > 0, "Reward rate must be positive");
        rewardRatePerBlock = _newRewardRatePerBlock;
        lastUpdateBlock = block.number;
    }

    /**
     * @dev Admin function to set a new claim interval in blocks.
     *      Only callable by an account with the _ADMIN role.
     * @param _niw The new claim interval.
     */
    function setClaimInterval(uint256 _niw) external onlyRole(_ADMIN) {
        claimInterval = _niw;
    }

    /**
     * @dev Admin function to set a new token contract for staking.
     *      Only callable by an account with the _ADMIN role.
     * @param _newToken The address of the new mintable ERC20 token contract.
     */
    function setToken(IEqualFiToken _newToken) external onlyRole(_ADMIN){
        token = _newToken;
    }

    /**
     * @dev Admin function to set a new NFT contract.
     *      Only callable by an account with the _ADMIN role.
     * @param _newNFT The address of the new ERC721 NFT contract.
     */
    function setNFT(IERC721 _newNFT) external onlyRole(_ADMIN) {
        nft = _newNFT;
    }

    /**
     * @dev Admin function to set a new staking cap.
     *      Only callable by an account with the _ADMIN role.
     * @param _newCap The new staking cap.
     */
    function setStakeCap(uint256 _newCap) external onlyRole(_ADMIN) {
        stakeCap = _newCap;
    }

    // ========================== Rescue Functions ==========================

    /**
     * @dev Rescue function to allow recovery of ERC20 tokens mistakenly sent to the contract.
     *      Only callable by an account with the _RESCUE role.
     * @param _ERC20 The address of the ERC20 token to rescue.
     * @param _dest The address to send the rescued tokens to.
     * @param _ERC20Amount The amount of tokens to rescue.
     */
    function moveERC20(IERC20 _ERC20, address _dest, uint _ERC20Amount) nonReentrant public onlyRole(_RESCUE) {
        IERC20(_ERC20).transfer(_dest, _ERC20Amount);
    }

    /**
     * @dev Rescue function to allow recovery of Ether mistakenly sent to the contract.
     *      Only callable by an account with the _RESCUE role.
     * @param _dest The address to send the rescued Ether to.
     * @param _etherAmount The amount of Ether to rescue.
     */
    function ethRescue(address payable _dest, uint _etherAmount) nonReentrant public onlyRole(_RESCUE) {
        _dest.transfer(_etherAmount);
    }
}
