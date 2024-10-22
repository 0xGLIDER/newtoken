// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./LPToken.sol";  // Import your custom ERC20 token
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ERC20Factory.sol";

interface TokenIface is IERC20 {
    function burnFrom(address user, uint256 amount) external;
}

contract MergedStablecoinLending is AccessControl, ReentrancyGuard {
    IERC20 public stablecoin;
    IERC20 public collateralToken;
    LPToken public depositShares; // Use MyERC20Token that supports minting and burning

    TokenIface public token;
    ERC20Factory public factory;

    uint256 public constant COLLATERALIZATION_RATIO = 150; // 150% collateralization
    uint256 public BORROW_FEE = 300; // 3% fee in basis points
    uint256 public LOAN_DURATION_IN_BLOCKS = 241920;
    uint256 public totalDeposits;
    uint256 public totalLoans;

    uint256 public totalRewardFees;
    uint256 public totalAdminFees;
    uint256 public accRewardPerShare;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    struct Loan {
        uint256 amount;
        uint256 collateral;
        uint256 borrowBlock;
        bool isFlashLoan;
        bool isRepaid;
    }

    struct UserDeposit {
        uint256 amount;
        uint256 rewardDebt;
    }

    mapping(address => Loan) public loans;
    mapping(address => UserDeposit) public deposits;

    event PoolInitialized(address indexed initializer, address depositShareToken);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 fee, uint256 collateral, bool isFlashLoan);
    event Repaid(address indexed user, uint256 amount, uint256 collateralReturned);
    event RewardsClaimed(address indexed user, uint256 amount);
    event FeesWithdrawn(address indexed admin, uint256 amount);
    event ForcedRepayment(address indexed user, uint256 amount, uint256 collateralUsed);

    constructor(
        IERC20 _stablecoin,
        IERC20 _collateralToken,
        TokenIface _token,
        ERC20Factory _factory
    ) {
        stablecoin = _stablecoin;
        collateralToken = _collateralToken;
        token = _token;
        factory = _factory;

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ADMIN_ROLE, _msgSender());
    }

    // Initialize the lending pool by creating an ERC20 token for deposit shares
    function initializePool(string memory name, string memory symbol) external onlyRole(ADMIN_ROLE) {
        require(address(depositShares) == address(0), "Pool already initialized");

        // Use the external factory to create the ERC20 token
        depositShares = factory.createERC20(name, symbol, address(this));

        // Grant the lending pool (this contract) the MINTER_ROLE so it can mint LP tokens
        // depositShares.grantRole(depositShares.MINTER_ROLE(), address(this));

        emit PoolInitialized(_msgSender(), address(depositShares));
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");

        updatePool();

        UserDeposit storage userDeposit = deposits[_msgSender()];
        if (userDeposit.amount > 0) {
            uint256 pending = _pendingRewards(_msgSender());
            if (pending > 0) {
                stablecoin.transfer(_msgSender(), pending);
                emit RewardsClaimed(_msgSender(), pending);
            }
        }

        stablecoin.transferFrom(_msgSender(), address(this), amount);

        uint256 sharesToMint = _sharesForAmount(amount);
        depositShares.mint(_msgSender(), sharesToMint);  // Mint LP tokens using the public mint function

        userDeposit.amount += amount;
        userDeposit.rewardDebt = (userDeposit.amount * accRewardPerShare) / 1e12;
        totalDeposits += amount;

        emit Deposited(_msgSender(), amount);
    }




    function withdraw(uint256 shares) external nonReentrant {
        require(shares > 0, "Shares must be greater than zero");

        // Fetch user deposit data
        UserDeposit storage userDeposit = deposits[_msgSender()];
        uint256 totalUserShares = depositShares.balanceOf(_msgSender());
        require(totalUserShares >= shares, "Insufficient shares to withdraw");

        // Calculate the amount of stablecoins corresponding to the shares to be burned
        uint256 amountToWithdraw = _amountForShares(shares);
        require(stablecoin.balanceOf(address(this)) >= amountToWithdraw, "Insufficient stablecoin balance in the pool");

        updatePool(); // Update pool with any pending rewards

        // Calculate the pending rewards for the user
        uint256 pendingRewards = (userDeposit.amount * accRewardPerShare) / 1e12 - userDeposit.rewardDebt;
        uint256 totalWithdrawalAmount = amountToWithdraw + pendingRewards;

        // Burn the shares from the user
        depositShares.burnFrom(_msgSender(), shares);

        // Transfer the calculated stablecoin amount + pending rewards to the user
        stablecoin.transfer(_msgSender(), totalWithdrawalAmount);

        // Update user deposit information
        userDeposit.amount -= amountToWithdraw;
        userDeposit.rewardDebt = (userDeposit.amount * accRewardPerShare) / 1e12;

        // Update total deposits
        totalDeposits -= amountToWithdraw;

        emit Withdrawn(_msgSender(), totalWithdrawalAmount);
    }

    function _amountForShares(uint256 shares) internal view returns (uint256) {
        uint256 totalShares = depositShares.totalSupply();
        uint256 poolBalance = stablecoin.balanceOf(address(this));

        return (shares * poolBalance) / totalShares;
    }

    // Borrow stablecoins from the pool (non-flash loan)
    function borrow(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(loans[_msgSender()].amount == 0, "Already have an active loan");

        uint256 initialGas = gasleft(); // Record the initial amount of gas at the start

        uint256 collateralAmount = (amount * COLLATERALIZATION_RATIO) / 100;
        uint256 fee = (amount * BORROW_FEE) / 10000; // 3% fee
        uint256 totalAmount = amount; // Only consider the amount for total deposits

        require(totalDeposits >= totalAmount, "Not enough stablecoins in the pool");

        // Transfer the collateral from the borrower
        collateralToken.transferFrom(_msgSender(), address(this), collateralAmount);

        // Calculate the gas fee dynamically and burn it
        uint256 gasFee = calculateGasFee(initialGas);
        token.burnFrom(_msgSender(), gasFee); // Collect gas fee in tokens by burning them

        // Create a loan for the borrower, storing the block number
        loans[_msgSender()] = Loan({
            amount: amount,
            collateral: collateralAmount,
            borrowBlock: block.number, // Store the block number instead of timestamp
            isFlashLoan: false,
            isRepaid: false
        });

        totalLoans += amount;
        totalDeposits -= amount; // Only subtract the borrowed amount, not the fee
        stablecoin.transfer(_msgSender(), amount); // Transfer the borrowed amount to the user

        // Split the fee between rewards and admin
        uint256 rewardFee = fee / 2;
        totalRewardFees += rewardFee;
        totalAdminFees += fee - rewardFee;

        emit Borrowed(_msgSender(), amount, fee, collateralAmount, false);
    }


    function repay() external nonReentrant {
        Loan storage loan = loans[_msgSender()];
        require(loan.amount > 0, "No active loan");

        uint256 totalRepayAmount = loan.amount; // The amount to repay
        uint256 collateralFee = (loan.amount * BORROW_FEE) / 10000; // Calculate the 3% fee on the loan amount
        uint256 collateralToReturn = loan.collateral - collateralFee; // Collateral to return minus the fee

        // Transfer the repayment amount from the borrower to the contract
        stablecoin.transferFrom(_msgSender(), address(this), totalRepayAmount);

        // Return the collateral minus the fee to the borrower
        collateralToken.transfer(_msgSender(), collateralToReturn);

        // Update total deposits and loans
        totalDeposits += loan.amount;
        totalLoans -= loan.amount;

        // Clear the loan
        loan.amount = 0;
        loan.collateral = 0;
        loan.isRepaid = true;

     emit Repaid(_msgSender(), totalRepayAmount, collateralToReturn);
    }


    function forceRepayment(address borrower) external onlyRole(ADMIN_ROLE) nonReentrant {
        Loan storage loan = loans[borrower];
        require(loan.amount > 0, "No active loan");
        require(block.number >= loan.borrowBlock + LOAN_DURATION_IN_BLOCKS, "Loan duration has not expired");

        uint256 totalRepayAmount = loan.amount; // Full loan amount to be repaid
        uint256 collateralFee = (loan.amount * BORROW_FEE) / 10000; // 3% fee on the loan amount
        uint256 collateralToReturn = loan.collateral - collateralFee; // Collateral minus the fee

        // Transfer the repayment amount from the admin to the contract
        stablecoin.transferFrom(_msgSender(), address(this), totalRepayAmount);

        // Return the collateral minus the fee to the borrower
        collateralToken.transfer(borrower, collateralToReturn);

        // Update total loans
        totalLoans -= loan.amount;

        // Clear the loan details
        loan.amount = 0;
        loan.collateral = 0;
        loan.isRepaid = true;

        emit ForcedRepayment(borrower, totalRepayAmount, collateralToReturn);
    }


    function borrowAndExecute(
        uint256 amount,
        uint256 collateralAmount,
        address callbackContract,
        bytes calldata callbackData
    ) external nonReentrant {
        require(loans[_msgSender()].amount == 0, "Already have an active loan");
        require(amount > 0, "Amount must be greater than zero");
        require(collateralAmount >= (amount * COLLATERALIZATION_RATIO) / 100, "Insufficient collateral");

        uint256 fee = (amount * BORROW_FEE) / 10000;

        require(stablecoin.balanceOf(address(this)) >= amount, "Not enough stablecoins in the pool");

        collateralToken.transferFrom(_msgSender(), address(this), collateralAmount);

        loans[_msgSender()] = Loan({
            amount: amount,
            collateral: collateralAmount,
            borrowBlock: block.number,
            isFlashLoan: true,
            isRepaid: false
        });

        totalLoans += amount;
        totalDeposits -= amount;
        stablecoin.transfer(_msgSender(), amount);

        (bool success, ) = callbackContract.call(callbackData);
        require(success, "Callback execution failed");

        uint256 repaymentAmount = amount + fee;
        require(stablecoin.balanceOf(address(this)) >= repaymentAmount, "Insufficient funds for repayment");

        totalDeposits += repaymentAmount;
        totalLoans -= amount;

        collateralToken.transfer(_msgSender(), collateralAmount - fee);

        totalRewardFees += fee / 2;
        totalAdminFees += fee / 2;

        emit Borrowed(_msgSender(), amount, fee, collateralAmount, true);
        emit Repaid(_msgSender(), repaymentAmount, collateralAmount - fee);
    }

    function updatePool() internal {
        if (totalDeposits == 0) {
            return;
        }

        uint256 reward = totalRewardFees;
        accRewardPerShare += (reward * 1e12) / totalDeposits;
        totalRewardFees = 0;
    }

    function _pendingRewards(address user) internal view returns (uint256) {
        UserDeposit storage userDeposit = deposits[user];
        uint256 pending = (userDeposit.amount * accRewardPerShare) / 1e12 - userDeposit.rewardDebt;
        return pending;
    }

    function _sharesForAmount(uint256 amount) internal view returns (uint256) {
        uint256 totalShares = depositShares.totalSupply();
        uint256 poolBalance = stablecoin.balanceOf(address(this));

        // If no shares exist, mint 1:1 LP tokens for the first depositor
        if (totalShares == 0 || poolBalance == 0) {
            return amount;
        }

        // Otherwise, calculate shares proportionally to the deposit
        return (amount * totalShares) / poolBalance;
    }

    function viewPendingRewards(address user) external view returns (uint256) {
        return _pendingRewards(user);
    }

    function setLoanDurationInBlocks(uint256 newLoanDuration) external onlyRole(ADMIN_ROLE) {
        require(newLoanDuration > 0, "Loan duration must be greater than zero");
        LOAN_DURATION_IN_BLOCKS = newLoanDuration;
    }

    function setFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        require(newFee > 0, "Fee must be greater than zero");
        BORROW_FEE = newFee;
    }

    function calculateGasFee(uint256 initialGas) internal view returns (uint256) {
        uint256 gasUsed = initialGas - gasleft();  // Calculate gas used during function execution
        uint256 gasFee = gasUsed * tx.gasprice;    // Calculate fee based on gas used and current gas price
        return gasFee;
    }


    function withdrawFees(uint256 amount) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(amount <= totalAdminFees, "Insufficient admin fee balance");
        totalAdminFees -= amount;
        stablecoin.transfer(_msgSender(), amount);

        emit FeesWithdrawn(_msgSender(), amount);
    }
}
