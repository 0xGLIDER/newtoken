// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface TokenIface is IERC20 {
    function burnFrom(address user, uint256 amount) external;
}

contract StablecoinLending is AccessControl, ReentrancyGuard {
    TokenIface public token;
    address public vault;

    uint256 public constant COLLATERALIZATION_RATIO = 150; // 150% collateralization
    uint256 public constant LIQUIDATION_THRESHOLD = 120; // 120% collateralization
    uint256 public constant LIQUIDATION_PENALTY = 10; // 10% penalty on collateral
    uint256 public gasFeeMultiplier = 3;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    struct Loan {
        uint256 amount;
        uint256 collateral;
        uint256 borrowBlock; // Track the block number at borrowing
        bool isFlashLoan; // Flag to differentiate between flash loans and non-flash loans
        bool isRepaid; // Tracks if the loan has been repaid
    }

    struct UserDeposit {
        uint256 amount;
        uint256 rewardDebt; // Used to calculate pending rewards
    }

    struct Pool {
        IERC20 stablecoin;
        IERC20 collateralToken;
        uint256 totalDeposits;
        uint256 totalLoans;
        uint256 accRewardPerShare;
        uint256 totalRewardFees;
        uint256 totalAdminFees;
        uint256 borrowFee; // Pool-specific borrow fee (in basis points)
        uint256 loanDurationInBlocks; // Pool-specific loan duration
        mapping(address => UserDeposit) userDeposits;
        mapping(address => Loan) userLoans;
    }

    Pool[] public pools; // Array of pools

    event PoolCreated(uint256 poolId, address indexed stablecoin, address indexed collateralToken);
    event Deposited(uint256 poolId, address indexed user, uint256 amount);
    event Withdrawn(uint256 poolId, address indexed user, uint256 amount);
    event Borrowed(uint256 poolId, address indexed user, uint256 amount, uint256 fee, uint256 collateral, bool isFlashLoan);
    event Repaid(uint256 poolId, address indexed user, uint256 amount, uint256 collateralReturned);
    event Liquidated(uint256 poolId, address indexed user, uint256 amount, uint256 collateralSeized);
    event RewardsClaimed(uint256 poolId, address indexed user, uint256 amount);
    event ForcedRepayment(uint256 poolId, address indexed user, uint256 amount, uint256 collateralUsed);
    event FeesWithdrawn(address indexed admin, uint256 amount);

    constructor(TokenIface _token, address _vault) {
        token = _token;
        vault = _vault;

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender()); // Assign the deployer as the default admin
        _grantRole(ADMIN_ROLE, _msgSender()); // Assign the deployer as the admin role
    }

    // Create a new pool with stablecoin and collateral token pair
    function createPool(
        IERC20 _stablecoin,
        IERC20 _collateralToken,
        uint256 _borrowFee,
        uint256 _loanDurationInBlocks
    ) external onlyRole(ADMIN_ROLE) {
        Pool storage newPool = pools.push();
        newPool.stablecoin = _stablecoin;
        newPool.collateralToken = _collateralToken;
        newPool.borrowFee = _borrowFee;
        newPool.loanDurationInBlocks = _loanDurationInBlocks;
        emit PoolCreated(pools.length - 1, address(_stablecoin), address(_collateralToken));
    }

    // Admin function to set borrow fee for a specific pool
    function setPoolBorrowFee(uint256 poolId, uint256 newBorrowFee) external onlyRole(ADMIN_ROLE) {
        require(newBorrowFee > 0, "Fee must be greater than zero");
        pools[poolId].borrowFee = newBorrowFee;
    }

    // Admin function to set loan duration for a specific pool
    function setPoolLoanDurationInBlocks(uint256 poolId, uint256 newLoanDuration) external onlyRole(ADMIN_ROLE) {
        require(newLoanDuration > 0, "Loan duration must be greater than zero");
        pools[poolId].loanDurationInBlocks = newLoanDuration;
    }

    // Admin function to set the gas fee multiplier
    function setGasFeeMultiplier(uint256 _newMultiplier) external onlyRole(ADMIN_ROLE) {
        require(_newMultiplier >= 0, "Can't be less than zero");
        gasFeeMultiplier = _newMultiplier;
    }

    // Function to set the loan duration for a specific pool after deployment
    function setLoanDurationInBlocks(uint256 poolId, uint256 newLoanDurationInBlocks) external onlyRole(ADMIN_ROLE) {
        require(poolId < pools.length, "Invalid pool ID");
        require(newLoanDurationInBlocks > 0, "Loan duration must be greater than zero");
    
        Pool storage pool = pools[poolId];
        pool.loanDurationInBlocks = newLoanDurationInBlocks;
    }

    // Function to set the borrow fee for a specific pool after deployment
    function setBorrowFee(uint256 poolId, uint256 newBorrowFee) external onlyRole(ADMIN_ROLE) {
        require(poolId < pools.length, "Invalid pool ID");
        require(newBorrowFee > 0, "Borrow fee must be greater than zero");

        Pool storage pool = pools[poolId];
        pool.borrowFee = newBorrowFee;
    }


    // Deposit stablecoins into a specific pool
    function deposit(uint256 poolId, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        Pool storage pool = pools[poolId];

        updatePool(poolId);

        UserDeposit storage userDeposit = pool.userDeposits[_msgSender()];
        uint256 userAmount = userDeposit.amount;
        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 rewardDebt = userDeposit.rewardDebt;

        // Calculate pending rewards only if user has an existing deposit
        if (userAmount > 0) {
            uint256 pending = (userAmount * accRewardPerShare) / 1e12 - rewardDebt;
            if (pending > 0) {
                // Check contract balance once and cache the result
                uint256 contractBalance = pool.stablecoin.balanceOf(address(this));
                require(contractBalance >= pending, "Insufficient balance in contract for rewards");

                // Use transfer instead of transfer call to avoid reentrancy risks
                bool success = pool.stablecoin.transfer(_msgSender(), pending);
                require(success, "Reward transfer failed");
            
                emit RewardsClaimed(poolId, _msgSender(), pending);
            }
        }

        // Transfer new deposit amount from the sender to the contract
        bool depositSuccess = pool.stablecoin.transferFrom(_msgSender(), address(this), amount);
        require(depositSuccess, "Deposit Failed");

        // Update the user's deposit and reward debt in local variables
        userDeposit.amount = userAmount + amount;
        userDeposit.rewardDebt = (userDeposit.amount * accRewardPerShare) / 1e12;

        // Update the pool's total deposits
        pool.totalDeposits += amount;

        emit Deposited(poolId, _msgSender(), amount);
    }


    // Withdraw stablecoins from a specific pool
    function withdraw(uint256 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        UserDeposit storage userDeposit = pool.userDeposits[msg.sender];

        require(userDeposit.amount >= amount, "Insufficient deposit balance");

        updatePool(poolId);

        uint256 userAmount = userDeposit.amount;
        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 rewardDebt = userDeposit.rewardDebt;

        // Calculate pending rewards
        uint256 pending = (userAmount * accRewardPerShare) / 1e12 - rewardDebt;
    
        // Check contract balance once and reuse the result
        uint256 contractBalance = pool.stablecoin.balanceOf(address(this));

        // Claim pending rewards if any
        if (pending > 0) {
            require(contractBalance >= pending, "Insufficient balance in contract for rewards");

            // Transfer the pending rewards to the user
            bool rewardSuccess = pool.stablecoin.transfer(msg.sender, pending);
            require(rewardSuccess, "Reward transfer failed");
        
            emit RewardsClaimed(poolId, msg.sender, pending);
        
            // Update the contract's balance after transferring rewards
            contractBalance -= pending;
        }

        // Ensure the contract has enough balance for the withdrawal
        require(contractBalance >= amount, "Insufficient balance in contract for withdrawal");

        // Transfer the withdrawal amount to the user
        bool withdrawSuccess = pool.stablecoin.transfer(msg.sender, amount);
        require(withdrawSuccess, "Withdrawal transfer failed");

        // Update user's deposit and reward debt
        userDeposit.amount = userAmount - amount;
        userDeposit.rewardDebt = (userDeposit.amount * accRewardPerShare) / 1e12;

        // Update the pool's total deposits
        pool.totalDeposits -= amount;

        emit Withdrawn(poolId, msg.sender, amount);
    }


    // View function to see pending rewards for a user in a specific pool
    function viewPendingRewards(uint256 poolId, address user) external view returns (uint256) {
        Pool storage pool = pools[poolId];
        UserDeposit storage userDeposit = pool.userDeposits[user];
        uint256 _accRewardPerShare = pool.accRewardPerShare;

        if (pool.totalDeposits > 0) {
            uint256 reward = pool.totalRewardFees;
            _accRewardPerShare += (reward * 1e12) / pool.totalDeposits;
        }

        uint256 pending = (userDeposit.amount * _accRewardPerShare) / 1e12 - userDeposit.rewardDebt;
        return pending;
    }

    // Update the pool's reward calculations
    function updatePool(uint256 poolId) internal {
        Pool storage pool = pools[poolId];
        if (pool.totalDeposits == 0) {
            return;
        }

        uint256 reward = pool.totalRewardFees;
        pool.accRewardPerShare += (reward * 1e12) / pool.totalDeposits;
        pool.totalRewardFees = 0;
    }

    // Borrow stablecoins from a specific pool
    function borrow(uint256 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        require(amount > 0, "Amount must be greater than zero");
        require(pool.userLoans[msg.sender].amount == 0, "Already have an active loan");

        uint256 initialGas = gasleft();

        uint256 collateralAmount = (amount * COLLATERALIZATION_RATIO) / 100;
        uint256 fee = (amount * pool.borrowFee) / 10000;
        uint256 totalAmount = amount;

        require(pool.totalDeposits >= totalAmount, "Not enough stablecoins in the pool");

        pool.collateralToken.transferFrom(msg.sender, address(this), collateralAmount);

        uint256 gasFee = calculateGasFee(initialGas, amount);
        token.burnFrom(_msgSender(), gasFee);

        pool.userLoans[msg.sender] = Loan({
            amount: amount,
            collateral: collateralAmount,
            borrowBlock: block.number,
            isFlashLoan: false,
            isRepaid: false
        });

        pool.totalLoans += amount;
        pool.totalDeposits -= amount;
        pool.stablecoin.transfer(msg.sender, amount);

        uint256 rewardFee = fee / 2;
        pool.totalRewardFees += rewardFee;
        pool.totalAdminFees += fee - rewardFee;

        emit Borrowed(poolId, msg.sender, amount, fee, collateralAmount, false);
    }


    function repay(uint256 poolId) external nonReentrant {
        Pool storage pool = pools[poolId];
        Loan storage loan = pool.userLoans[msg.sender];
    
        require(loan.amount > 0, "No active loan");
        require(!loan.isRepaid, "Loan already repaid");

        uint256 totalRepayAmount = loan.amount;

        // Transfer the repayment amount from the borrower to the contract
        require(pool.stablecoin.transferFrom(msg.sender, address(this), totalRepayAmount), "Repayment failed");

        pool.totalDeposits += loan.amount;

        // Calculate the collateral fee
        uint256 collateralFee = (loan.amount * pool.borrowFee) / 10000;
        uint256 collateralToReturn = loan.collateral - collateralFee;

        pool.totalLoans -= loan.amount;
        loan.amount = 0;
        loan.collateral = 0;
        loan.isRepaid = true;

        // Return the collateral minus the collateral fee to the borrower
        pool.collateralToken.transfer(msg.sender, collateralToReturn);

        emit Repaid(poolId, msg.sender, totalRepayAmount, collateralToReturn);
    }


    // Force repayment of a loan by an admin if the loan duration has expired
    function forceRepayment(uint256 poolId, address borrower) external onlyRole(ADMIN_ROLE) nonReentrant {
        Pool storage pool = pools[poolId];
        Loan storage loan = pool.userLoans[borrower];
        require(loan.amount > 0, "No active loan");
        require(!loan.isRepaid, "Loan already repaid");

        require(block.number >= loan.borrowBlock + pool.loanDurationInBlocks, "Loan duration has not expired");

        uint256 totalRepayAmount = loan.amount;
        uint256 fee = (loan.amount * pool.borrowFee) / 10000;
        uint256 repayAmountWithFee = totalRepayAmount + fee;

        require(loan.collateral >= repayAmountWithFee, "Insufficient collateral for forced repayment");

        loan.collateral -= repayAmountWithFee;
        pool.totalDeposits += totalRepayAmount;
        pool.totalLoans -= loan.amount;

        uint256 remainingCollateral = loan.collateral;
        loan.amount = 0;
        loan.collateral = 0;
        loan.isRepaid = true;

        if (remainingCollateral > 0) {
            pool.collateralToken.transfer(borrower, remainingCollateral);
        }

        emit ForcedRepayment(poolId, borrower, totalRepayAmount, remainingCollateral);
    }

     // Borrow stablecoins from the pool with flash loan support
    function borrowAndExecute(
        uint256 poolId,
        uint256 amount,
        uint256 collateralAmount,
        address callbackContract,
        bytes calldata callbackData
    ) external nonReentrant {
        Pool storage pool = pools[poolId];
        require(pool.userLoans[msg.sender].amount == 0, "Already have an active loan");
        require(amount > 0, "Amount must be greater than zero");
        require(collateralAmount >= (amount * COLLATERALIZATION_RATIO) / 100, "Insufficient collateral");

        // Execute loan issuance
        issueLoan(poolId, amount, collateralAmount);

        // Execute callback on the external contract
        executeCallback(callbackContract, callbackData);

        // Finalize the repayment after callback execution
        finalizeRepayment(poolId, amount);
    }

    // Helper function to issue the loan
    function issueLoan(
        uint256 poolId,
        uint256 amount,
        uint256 collateralAmount
        ) internal {
        Pool storage pool = pools[poolId];

        uint256 fee = (amount * pool.borrowFee) / 10000; // Pool-specific fee on loan amount
        require(pool.totalDeposits >= amount, "Not enough stablecoins in the pool");

        // Transfer the collateral from the borrower to the contract
        pool.collateralToken.transferFrom(msg.sender, address(this), collateralAmount);

        // Record the loan details
        pool.userLoans[msg.sender] = Loan({
            amount: amount,
            collateral: collateralAmount,
            borrowBlock: block.number,
            isFlashLoan: true,
            isRepaid: false
        });

        pool.totalLoans += amount;
        pool.totalDeposits -= amount;
        pool.stablecoin.transfer(msg.sender, amount); // Send the loan amount to the user

        emit Borrowed(poolId, msg.sender, amount, fee, collateralAmount, true);
    }

    // Helper function to execute the callback
    function executeCallback(address callbackContract, bytes calldata callbackData) internal {
        (bool success, ) = callbackContract.call(callbackData);
        require(success, "Callback execution failed");
    }

    // Helper function to finalize repayment
    function finalizeRepayment(uint256 poolId, uint256 amount) internal {
        Pool storage pool = pools[poolId];

        uint256 fee = (amount * pool.borrowFee) / 10000; // Calculate the fee again
        uint256 repaymentAmount = amount + fee;

        require(pool.stablecoin.balanceOf(address(this)) >= repaymentAmount, "Insufficient funds for repayment");

        pool.totalDeposits += repaymentAmount; // Add back the repayment amount (loan + fee)
        pool.totalLoans -= amount;

        uint256 collateralFee = (amount * pool.borrowFee) / 10000; // Pool-specific fee on the collateral
        uint256 collateralToReturn = pool.userLoans[msg.sender].collateral - collateralFee;

        // Mark the loan as repaid
        pool.userLoans[msg.sender].amount = 0;
        pool.userLoans[msg.sender].collateral = 0;
        pool.userLoans[msg.sender].isRepaid = true;

        // Return the collateral minus the fee to the borrower
        pool.collateralToken.transfer(msg.sender, collateralToReturn);

        // Split the fee between rewards and admin
        uint256 rewardFee = fee / 2;
        pool.totalRewardFees += rewardFee;
        pool.totalAdminFees += fee - rewardFee;

        emit Repaid(poolId, msg.sender, repaymentAmount, collateralToReturn);
}


    // Helper function to calculate the gas fee dynamically
    function calculateGasFee(uint256 initialGas, uint256 borrowAmount) internal view returns (uint256) {
        uint256 gasUsed = initialGas - gasleft();
        uint256 gasFee = gasUsed * tx.gasprice;
        uint256 adjustedGasFee = gasFee * borrowAmount * gasFeeMultiplier;

        uint256 gasFeeCap = 1e19;

        if (adjustedGasFee > gasFeeCap) {
            return gasFeeCap;
        } else {
            return adjustedGasFee;
        }
    }

    // Function to get a user's deposit in a specific pool
    function getUserDepositInPool(uint256 poolId, address user) external view returns (uint256) {
        require(poolId < pools.length, "Invalid pool ID");
        Pool storage pool = pools[poolId];
        return pool.userDeposits[user].amount;
    }


    // Function to get a user's pending rewards in a specific pool
    function getPendingRewardsInPool(uint256 poolId, address user) external view returns (uint256) {
        require(poolId < pools.length, "Invalid pool ID");
        return _calculatePendingRewards(poolId, user);
    }

    // Internal helper function to calculate pending rewards for a user in a specific pool
    function _calculatePendingRewards(uint256 poolId, address user) internal view returns (uint256) {
        Pool storage pool = pools[poolId];
        UserDeposit storage userDeposit = pool.userDeposits[user];
        uint256 accRewardPerShare = pool.accRewardPerShare;

        if (pool.totalDeposits > 0) {
            uint256 reward = pool.totalRewardFees;
            accRewardPerShare += (reward * 1e12) / pool.totalDeposits;
        }

        uint256 pending = (userDeposit.amount * accRewardPerShare) / 1e12 - userDeposit.rewardDebt;
        return pending;
    }




    // Admin function to withdraw admin fees for a specific pool
    function withdrawAdminFees(uint256 poolId) external onlyRole(ADMIN_ROLE) nonReentrant {
        Pool storage pool = pools[poolId];
        require(pool.totalAdminFees > 0, "No admin fees to withdraw");

        pool.stablecoin.transfer(vault, pool.totalAdminFees);
        emit FeesWithdrawn(_msgSender(), pool.totalAdminFees);

        pool.totalAdminFees = 0;
    }

    // Function to check an ERC20 token balance in the contract
    function checkTokenBalance(IERC20 _token) external view returns (uint256) {
        return _token.balanceOf(address(this));
    }
}
