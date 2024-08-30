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
                stablecoin.transfer(_msgSender(), pending);
                emit RewardsClaimed(_msgSender(), pending);
            }
        }

        stablecoin.transferFrom(_msgSender(), address(this), amount);
        userDeposit.amount += amount;
        userDeposit.rewardDebt = (userDeposit.amount * accRewardPerShare) / 1e12;
        totalDeposits += amount;

        emit Deposited(_msgSender(), amount);
    }

    // Withdraw stablecoins from the pool
    function withdraw(uint256 amount) external nonReentrant {
        UserDeposit storage userDeposit = deposits[_msgSender()];
        require(userDeposit.amount >= amount, "Insufficient deposit balance");

        updatePool();

        uint256 pending = (userDeposit.amount * accRewardPerShare) / 1e12 - userDeposit.rewardDebt;
        if (pending > 0) {
            stablecoin.transfer(_msgSender(), pending);
            emit RewardsClaimed(_msgSender(), pending);
        }

        userDeposit.amount -= amount;
        userDeposit.rewardDebt = (userDeposit.amount * accRewardPerShare) / 1e12;
        totalDeposits -= amount;

        stablecoin.transfer(_msgSender(), amount);
        emit Withdrawn(_msgSender(), amount);
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
            stablecoin.transfer(_msgSender(), pending);
            emit RewardsClaimed(_msgSender(), pending);
        }

        userDeposit.rewardDebt = (userDeposit.amount * accRewardPerShare) / 1e12;
    }

    // Borrow stablecoins from the pool (non-flash loan)
    function borrow(uint256 amount, uint256 collateralAmount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(collateralAmount >= (amount * COLLATERALIZATION_RATIO) / 100, "Insufficient collateral");

        uint256 fee = (amount * BORROW_FEE) / 10000;
        uint256 totalAmount = amount + fee;

        require(totalDeposits >= totalAmount, "Not enough stablecoins in the pool");

        // Transfer collateral
        collateralToken.transferFrom(_msgSender(), address(this), collateralAmount);

        // Store the loan details
        loans[_msgSender()] = Loan({
            amount: amount,
            collateral: collateralAmount,
            borrowTimestamp: block.timestamp,
            isFlashLoan: false
        });

        totalLoans += amount;
        totalDeposits -= totalAmount;
        stablecoin.transfer(_msgSender(), amount);

        // Split the fee: 50% for rewards, 50% for admin fees
        uint256 rewardFee = fee / 2;
        totalRewardFees += rewardFee;
        totalAdminFees += fee - rewardFee;

        emit Borrowed(_msgSender(), amount, fee, collateralAmount, false);
    }

    // Repay the loan and get collateral back (non-flash loan)
    function repay(uint256 amount) external nonReentrant {
        Loan storage loan = loans[_msgSender()];
        require(loan.amount > 0, "No active loan");
        require(!loan.isFlashLoan, "Cannot repay a flash loan using this function");
        require(amount >= loan.amount, "Amount must cover the loan");

        stablecoin.transferFrom(_msgSender(), address(this), amount);

        uint256 collateralToReturn = loan.collateral;
        loan.amount = 0;
        loan.collateral = 0;
        totalLoans -= amount;
        totalDeposits += amount;

        collateralToken.transfer(_msgSender(), collateralToReturn);

        emit Repaid(_msgSender(), amount, collateralToReturn);
    }

    // Borrow stablecoins from the pool with flash loan support
    function borrowAndExecute(uint256 amount, uint256 collateralAmount, address callbackContract, bytes calldata callbackData) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(collateralAmount >= (amount * COLLATERALIZATION_RATIO) / 100, "Insufficient collateral");

        uint256 fee = (amount * BORROW_FEE) / 10000;
        uint256 totalAmount = amount + fee;

        require(totalDeposits >= totalAmount, "Not enough stablecoins in the pool");

        // Transfer collateral
        collateralToken.transferFrom(_msgSender(), address(this), collateralAmount);

        // Store the loan details
        loans[_msgSender()] = Loan({
            amount: amount,
            collateral: collateralAmount,
            borrowTimestamp: block.timestamp,
            isFlashLoan: true
        });

        totalLoans += amount;
        totalDeposits -= totalAmount;

        // Transfer borrowed amount to the borrower
        stablecoin.transfer(_msgSender(), amount);

        // Execute the callback function
        (bool success, ) = callbackContract.call(callbackData);
        require(success, "Callback execution failed");

        // The borrower must repay within the same transaction
        uint256 repaymentAmount = amount + fee;
        require(stablecoin.balanceOf(address(this)) >= repaymentAmount, "Insufficient funds for repayment");

        // Reset the loan details
        totalDeposits += repaymentAmount;
        totalLoans -= amount;
        uint256 collateralToReturn = loans[_msgSender()].collateral;
        loans[_msgSender()].amount = 0;
        loans[_msgSender()].collateral = 0;

        // Return collateral to the borrower
        collateralToken.transfer(_msgSender(), collateralToReturn);

        // Split the fee: 50% for rewards, 50% for admin fees
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

        loan.amount = 0;
        loan.collateral = 0;
        totalLoans -= loan.amount;

        // Seize collateral
        collateralToken.transfer(_msgSender(), collateralToSeize);

        emit Liquidated(user, loan.amount, collateralToSeize);
    }

    // Get the details of the user's loan
    function getLoanDetails(address user) external view returns (uint256 amount, uint256 collateral, uint256 borrowTimestamp, bool isFlashLoan) {
        Loan storage loan = loans[user];
        return (loan.amount, loan.collateral, loan.borrowTimestamp, loan.isFlashLoan);
    }

    // Admin function to withdraw non-reward fees (admin fees)
    function withdrawFees(uint256 amount) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(amount <= totalAdminFees, "Insufficient admin fee balance");
        totalAdminFees -= amount;
        stablecoin.transfer(_msgSender(), amount);

        emit FeesWithdrawn(_msgSender(), amount);
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
