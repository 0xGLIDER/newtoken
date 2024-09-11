// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract StablecoinLending is AccessControl, ReentrancyGuard {
    IERC20 public stablecoin;
    IERC20 public collateralToken;

    uint256 public constant COLLATERALIZATION_RATIO = 150; // 150% collateralization
    uint256 public constant BORROW_FEE = 300; // 3% fee in basis points
    uint256 public constant LOAN_DURATION = 14 days; // Loans are valid for 2 weeks
    uint256 public constant LIQUIDATION_THRESHOLD = 120; // 120% collateralization
    uint256 public constant LIQUIDATION_PENALTY = 10; // 10% penalty on collateral
    uint256 public totalDeposits;
    uint256 public totalLoans;

    uint256 public totalRewardFees; // Total rewards fees to be distributed
    uint256 public totalAdminFees; // Total fees not for rewards (admin fees)
    uint256 public accRewardPerShare; // Accumulated rewards per share, scaled by 1e12

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    struct Loan {
        uint256 amount;
        uint256 collateral;
        uint256 borrowTimestamp;
        bool isFlashLoan; // Flag to differentiate between flash loans and non-flash loans
        bool isRepaid; // Tracks if the loan has been repaid
    }

    struct UserDeposit {
        uint256 amount;
        uint256 rewardDebt; // Used to calculate pending rewards
    }

    mapping(address => UserDeposit) public deposits;
    mapping(address => Loan) public loans;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 fee, uint256 collateral, bool isFlashLoan);
    event Repaid(address indexed user, uint256 amount, uint256 collateralReturned);
    event Liquidated(address indexed user, uint256 amount, uint256 collateralSeized);
    event RewardsClaimed(address indexed user, uint256 amount);
    event FeesWithdrawn(address indexed admin, uint256 amount);
    event ForcedRepayment(address indexed user, uint256 amount, uint256 collateralUsed);

    constructor(IERC20 _stablecoin, IERC20 _collateralToken) {
        stablecoin = _stablecoin;
        collateralToken = _collateralToken;

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender()); // Assign the deployer as the default admin
        _grantRole(ADMIN_ROLE, _msgSender()); // Assign the deployer as the admin role
    }

    // Deposit stablecoins into the pool
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");

        updatePool();

        UserDeposit storage userDeposit = deposits[_msgSender()];
        if (userDeposit.amount > 0) {
            uint256 pending = (userDeposit.amount * accRewardPerShare) / 1e12 - userDeposit.rewardDebt;
            if (pending > 0) {
                require(stablecoin.balanceOf(address(this)) >= pending, "Insufficient balance in contract for rewards");
                stablecoin.transfer(_msgSender(), pending);
                emit RewardsClaimed(_msgSender(), pending);
            }
        }

        require(stablecoin.transferFrom(_msgSender(), address(this), amount), "Deposit Failed");
        userDeposit.amount += amount;
        userDeposit.rewardDebt = (userDeposit.amount * accRewardPerShare) / 1e12;
        totalDeposits += amount;

        emit Deposited(_msgSender(), amount);
    }

    // Withdraw stablecoins from the pool
    function withdraw(uint256 amount) external nonReentrant {
        UserDeposit storage userDeposit = deposits[msg.sender];
        require(userDeposit.amount >= amount, "Insufficient deposit balance");

        updatePool();

        uint256 pending = (userDeposit.amount * accRewardPerShare) / 1e12 - userDeposit.rewardDebt;
        if (pending > 0) {
            require(stablecoin.balanceOf(address(this)) >= pending, "Insufficient balance in contract for rewards");
            stablecoin.transfer(msg.sender, pending);
            emit RewardsClaimed(msg.sender, pending);
        }

        // Ensure there is enough balance in the contract to fulfill the withdrawal before updating state
        require(stablecoin.balanceOf(address(this)) >= amount, "Insufficient balance in contract for withdrawal");

        // Transfer stablecoins and then update the state
        stablecoin.transfer(msg.sender, amount);
        userDeposit.amount -= amount;
        userDeposit.rewardDebt = (userDeposit.amount * accRewardPerShare) / 1e12;
        totalDeposits -= amount;

        emit Withdrawn(msg.sender, amount);
    }

    // Update the pool with rewards
    function updatePool() internal {
        if (totalDeposits == 0) {
            return;
        }

        uint256 reward = totalRewardFees;
        accRewardPerShare += (reward * 1e12) / totalDeposits;
        totalRewardFees = 0; // Reset reward fees after distribution
    }

    // Claim rewards manually
    function claimRewards() external nonReentrant {
        updatePool();

        UserDeposit storage userDeposit = deposits[_msgSender()];
        uint256 pending = (userDeposit.amount * accRewardPerShare) / 1e12 - userDeposit.rewardDebt;
        if (pending > 0) {
            require(stablecoin.balanceOf(address(this)) >= pending, "Insufficient balance in contract for rewards");
            stablecoin.transfer(_msgSender(), pending);
            emit RewardsClaimed(_msgSender(), pending);
        }

        userDeposit.rewardDebt = (userDeposit.amount * accRewardPerShare) / 1e12;
    }

    // Borrow stablecoins from the pool (non-flash loan)
    function borrow(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(loans[msg.sender].amount == 0, "Already have an active loan");

        uint256 collateralAmount = (amount * COLLATERALIZATION_RATIO) / 100;
        uint256 fee = (amount * BORROW_FEE) / 10000; // 3% fee
        uint256 totalAmount = amount; // Only consider the amount for total deposits

        require(totalDeposits >= totalAmount, "Not enough stablecoins in the pool");

        // Transfer the collateral from the borrower
        collateralToken.transferFrom(msg.sender, address(this), collateralAmount);

        // Create a loan for the borrower
        loans[msg.sender] = Loan({
            amount: amount,
            collateral: collateralAmount,
            borrowTimestamp: block.timestamp,
            isFlashLoan: false,
            isRepaid: false
        });

        totalLoans += amount;
        totalDeposits -= amount; // Only subtract the borrowed amount, not the fee
        stablecoin.transfer(msg.sender, amount); // Transfer the borrowed amount to the user

        // Split the fee between rewards and admin
        uint256 rewardFee = fee / 2;
        totalRewardFees += rewardFee;
        totalAdminFees += fee - rewardFee;

        emit Borrowed(msg.sender, amount, fee, collateralAmount, false);
    }


    // Repay the loan and get collateral back (non-flash loan)
    function repay() external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.amount > 0, "No active loan");
        require(!loan.isFlashLoan, "Cannot repay a flash loan using this function");
        require(!loan.isRepaid, "Loan already repaid");

        uint256 totalRepayAmount = loan.amount; // Fee was already charged at borrowing

        // Transfer the repayment amount from the borrower to the contract
        require(stablecoin.transferFrom(msg.sender, address(this), totalRepayAmount), "Repayment failed");

        totalDeposits += loan.amount; // Add back only the borrowed amount (not including the fee)

        // Calculate the collateral to return minus the 3% fee
        uint256 collateralFee = (loan.amount * BORROW_FEE) / 10000; // 3% of loan amount as fee
        uint256 collateralToReturn = loan.collateral - collateralFee;

        totalLoans -= loan.amount;
        loan.amount = 0;
        loan.collateral = 0;
        loan.isRepaid = true;

        // Return the collateral minus the 3% fee to the borrower
        collateralToken.transfer(msg.sender, collateralToReturn);

        emit Repaid(msg.sender, totalRepayAmount, collateralToReturn);
    }



    // Forced repayment by the admin if the loan is not repaid within 2 weeks
    function forceRepayment(address borrower) external onlyRole(ADMIN_ROLE) nonReentrant {
        Loan storage loan = loans[borrower];
        require(loan.amount > 0, "No active loan");
        require(!loan.isRepaid, "Loan already repaid");
        require(block.timestamp >= loan.borrowTimestamp + LOAN_DURATION, "Loan duration has not expired");

        uint256 totalRepayAmount = loan.amount; // Fee already applied at borrowing time

        if (loan.collateral >= totalRepayAmount) {
            loan.collateral -= totalRepayAmount;
            totalDeposits += totalRepayAmount;
            totalLoans -= loan.amount;

            uint256 remainingCollateral = loan.collateral;
            loan.amount = 0;
            loan.collateral = 0;
            loan.isRepaid = true;

            if (remainingCollateral > 0) {
                collateralToken.transfer(borrower, remainingCollateral);
            }

            emit ForcedRepayment(borrower, totalRepayAmount, remainingCollateral);
        } else {
            revert("Insufficient collateral for forced repayment");
        }
    }

    // Borrow stablecoins from the pool with flash loan support
    function borrowAndExecute(
        uint256 amount,
        uint256 collateralAmount,
        address callbackContract,
        bytes calldata callbackData
        ) external nonReentrant {
        require(loans[msg.sender].amount == 0, "Already have an active loan");
        require(amount > 0, "Amount must be greater than zero");
        require(collateralAmount >= (amount * COLLATERALIZATION_RATIO) / 100, "Insufficient collateral");

        uint256 fee = (amount * BORROW_FEE) / 10000; // 3% fee on loan amount
        uint256 totalAmount = amount; // Only consider the loan amount for total deposits

        require(totalDeposits >= totalAmount, "Not enough stablecoins in the pool");

        // Transfer the collateral from the borrower to the contract
        collateralToken.transferFrom(_msgSender(), address(this), collateralAmount);

        // Record the loan details
        loans[_msgSender()] = Loan({
            amount: amount,
            collateral: collateralAmount,
            borrowTimestamp: block.timestamp,
            isFlashLoan: true,
            isRepaid: false
        });

        totalLoans += amount;
        totalDeposits -= amount; // Only subtract the loan amount, not the fee
        stablecoin.transfer(_msgSender(), amount); // Send the loan amount to the user

        // Execute callback on the external contract
        (bool success, ) = callbackContract.call(callbackData);
        require(success, "Callback execution failed");

        // Calculate the repayment amount (loan amount + fee)
        uint256 repaymentAmount = amount + fee;
        require(stablecoin.balanceOf(address(this)) >= repaymentAmount, "Insufficient funds for repayment");

        totalDeposits += repaymentAmount; // Add back the repayment amount (loan + fee)
        totalLoans -= amount;

        // Calculate the collateral to return minus the 3% fee
        uint256 collateralFee = (amount * BORROW_FEE) / 10000; // 3% of loan amount as collateral fee
        uint256 collateralToReturn = loans[_msgSender()].collateral - collateralFee;

        loans[_msgSender()].amount = 0;
        loans[_msgSender()].collateral = 0;
        loans[_msgSender()].isRepaid = true;

        // Return the collateral minus the fee to the borrower
        collateralToken.transfer(_msgSender(), collateralToReturn);

        // Split the fee between rewards and admin
        uint256 rewardFee = fee / 2;
        totalRewardFees += rewardFee;
        totalAdminFees += fee - rewardFee;

        emit Borrowed(_msgSender(), amount, fee, collateralAmount, true);
        emit Repaid(_msgSender(), repaymentAmount, collateralToReturn);
    }


    // Liquidate under-collateralized loans
    function liquidate(address user) external nonReentrant {
        Loan storage loan = loans[user];
        require(loan.amount > 0, "No active loan");

        uint256 collateralization = (loan.collateral * 100) / loan.amount;
        require(collateralization < LIQUIDATION_THRESHOLD, "Loan is not under-collateralized");

        uint256 penalty = (loan.collateral * LIQUIDATION_PENALTY) / 100;
        uint256 collateralToSeize = loan.collateral - penalty;

        totalLoans -= loan.amount;
        loan.amount = 0;
        loan.collateral = 0;

        collateralToken.transfer(_msgSender(), collateralToSeize);

        emit Liquidated(user, loan.amount, collateralToSeize);
    }

    // Get the details of the user's loan
    function getLoanDetails(address user) external view returns (uint256 amount, uint256 collateral, uint256 borrowTimestamp, bool isFlashLoan, bool isRepaid) {
        Loan storage loan = loans[user];
        return (loan.amount, loan.collateral, loan.borrowTimestamp, loan.isFlashLoan, loan.isRepaid);
    }

    // Admin function to withdraw non-reward fees (admin fees)
    function withdrawFees(uint256 amount) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(amount <= totalAdminFees, "Insufficient admin fee balance");
        totalAdminFees -= amount;
        stablecoin.transfer(_msgSender(), amount);

        emit FeesWithdrawn(_msgSender(), amount);
    }

    // Function to check an ERC20 token balance
    function checkTokenBalance (IERC20 token) public view returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        return balance;
    }

    // View function to see pending rewards for a user
    function viewPendingRewards(address user) external view returns (uint256) {
        UserDeposit storage userDeposit = deposits[user];
        uint256 _accRewardPerShare = accRewardPerShare;

        if (totalDeposits > 0) {
            uint256 reward = totalRewardFees;
            _accRewardPerShare += (reward * 1e12) / totalDeposits;
        }

        uint256 pending = (userDeposit.amount * _accRewardPerShare) / 1e12 - userDeposit.rewardDebt;
        return pending;
    }


    // Function to grant ADMIN_ROLE to an address
    function grantAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(ADMIN_ROLE, account);
    }

    // Function to revoke ADMIN_ROLE from an address
    function revokeAdminRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(ADMIN_ROLE, account);
    }
}