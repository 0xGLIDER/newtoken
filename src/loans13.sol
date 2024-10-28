// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin Contracts
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Import Custom Contracts
import "./LPToken.sol";          // Custom ERC20 LP Token with Mint/Burn functionality
import "./ERC20Factory.sol";     // Factory to create ERC20 tokens

/**
 * @title TokenIface
 * @dev Interface extending IERC20 with a burnFrom function.
 */
interface TokenIface is IERC20 {
    function burnFrom(address user, uint256 amount) external;
}

/**
 * @title EqualFiLending
 * @dev A lending pool contract where users can deposit stablecoins, receive LP tokens, and borrow against collateral.
 *      Rewards are implicitly handled within the pool’s liquidity, allowing LP tokens to be transferable without
 *      individual reward tracking.
 */
contract EqualFiLending is AccessControl, ReentrancyGuard {
    // ========================== State Variables ==========================

    // ERC20 Tokens
    IERC20 public stablecoin;             // Stablecoin used for deposits and loans
    IERC20 public collateralToken;        // Token used as collateral

    LPToken public depositShares;         // LP Token representing user shares in the pool

    TokenIface public token;              // Interface for burnFrom functionality
    EqualFiLPFactory public factory;          // Factory to create ERC20 tokens

 
    uint256 public COLLATERALIZATION_RATIO = 150; // 150% collateralization

    // Fees and Durations
    uint256 public BORROW_FEE = 300;                // 3% fee in basis points
    uint256 public LOAN_DURATION_IN_BLOCKS = 241920; // Approx. 14 days (assuming 5 sec blocks)

    // Pool Metrics
    uint256 public totalDeposits;        // Total stablecoins deposited by users
    uint256 public totalLoans;           // Total active loans
    uint256 public availableLiquidity;   // Liquidity available for borrowing
    uint256 public totalAdminFees;       // Total fees accumulated for admin
    uint256 public totalDepositorFees;   // Total fees accrued for depositors

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ========================== Structs ==========================

    /**
     * @dev Represents a loan taken by a user.
     */
    struct Loan {
        uint256 amount;        // Amount borrowed
        uint256 collateral;    // Collateral deposited
        uint256 borrowBlock;   // Block number when loan was taken
        bool isFlashLoan;      // Indicates if it's a flash loan
        bool isRepaid;         // Indicates if the loan has been repaid
    }

    // ========================== Mappings ==========================

    mapping(address => Loan) public loans; // Tracks loans per user

    // ========================== Events ==========================

    event PoolInitialized(address indexed initializer, address depositShareToken);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 fee, uint256 collateral, bool isFlashLoan);
    event Repaid(address indexed user, uint256 amount, uint256 collateralReturned);
    event FeesWithdrawn(address indexed admin, uint256 amount);
    event ForcedRepayment(address indexed user, uint256 amount, uint256 collateralUsed);

    // ========================== Constructor ==========================

    /**
     * @dev Initializes the contract by setting the stablecoin, collateral token, token interface, and factory.
     * Grants the deployer the default admin and admin roles.
     */
    constructor(
        IERC20 _stablecoin,
        IERC20 _collateralToken,
        TokenIface _token,
        EqualFiLPFactory _factory
    ) {
        stablecoin = _stablecoin;
        collateralToken = _collateralToken;
        token = _token;
        factory = _factory;

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ADMIN_ROLE, _msgSender());
    }

    // ========================== Initialization ==========================

    /**
     * @dev Initializes the lending pool by creating an ERC20 token for deposit shares (LP tokens).
     * Only callable once by an admin.
     * @param name Name of the LP token.
     * @param symbol Symbol of the LP token.
     */
    function initializePool(string memory name, string memory symbol, address admin) external onlyRole(ADMIN_ROLE) {
        require(address(depositShares) == address(0), "Pool already initialized");

        // Use the external factory to create the ERC20 token
        depositShares = factory.createLPToken(name, symbol, address(this));

        // Grant the lending pool (this contract) the MINTER_ROLE and BURNER_ROLE so it can mint and burn LP tokens
        depositShares.grantRole(depositShares.MINTER_ROLE(), address(this));
        depositShares.grantRole(depositShares.BURNER_ROLE(), address(this));
        depositShares.grantRole(depositShares.DEFAULT_ADMIN_ROLE(), admin);
       

        emit PoolInitialized(_msgSender(), address(depositShares));
    }

    // ========================== Deposit Function ==========================

    /**
     * @dev Allows users to deposit stablecoins into the pool and receive LP tokens.
     * LP tokens are minted proportionally based on the deposit relative to available liquidity.
     * @param amount Amount of stablecoins to deposit.
     */
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(address(depositShares) != address(0), "Pool not initialized");

        uint256 totalShares = depositShares.totalSupply();
        uint256 sharesToMint;

        if (totalShares == 0) {
            // First depositor sets the initial share value
            sharesToMint = amount;
        } else {
            // Mint LP tokens proportional to the deposit relative to pool's total assets
            uint256 poolTotalAssets = totalDeposits + totalDepositorFees; // Total pool assets excluding admin fees
            sharesToMint = (amount * totalShares) / poolTotalAssets;
        }

        // Transfer stablecoins from the user to the contract
        stablecoin.transferFrom(_msgSender(), address(this), amount);

        // Mint LP tokens to the user
        depositShares.mint(_msgSender(), sharesToMint);

        // Update pool metrics
        totalDeposits += amount;
        availableLiquidity += amount;

        emit Deposited(_msgSender(), amount);
    }

    // ========================== Withdraw Function ==========================

    /**
     * @dev Allows users to withdraw their stablecoins by burning their LP tokens.
     * Users receive a proportional share of their deposits and accrued fees.
     * @param sharesToBurn Number of LP tokens to burn.
     */
    function withdraw(uint256 sharesToBurn) external nonReentrant {
        require(sharesToBurn > 0, "Shares must be greater than zero");
        require(address(depositShares) != address(0), "Pool not initialized");

        uint256 totalShares = depositShares.totalSupply();
        require(totalShares > 0, "No shares exist");

        uint256 userShares = depositShares.balanceOf(_msgSender());
        require(userShares >= sharesToBurn, "Insufficient shares to burn");

        // Calculate the user's share proportion using high precision
        uint256 userShareFraction = (sharesToBurn * 1e18) / totalShares; // Using 1e18 for precision

        // Calculate the user's portion of totalDeposits
        uint256 userDepositedAmount = (totalDeposits * userShareFraction) / 1e18;

        // Calculate the user's portion of totalDepositorFees
        uint256 userDepositorFees = (totalDepositorFees * userShareFraction) / 1e18;

        // Total amount to withdraw
        uint256 amountToWithdraw = userDepositedAmount + userDepositorFees;

        // Burn the shares from the user
        depositShares.burnFrom(_msgSender(), sharesToBurn);

        // Transfer the stablecoin amount to the user
        stablecoin.transfer(_msgSender(), amountToWithdraw);

        // Update the totalDeposits and totalDepositorFees
        totalDeposits -= userDepositedAmount;
        totalDepositorFees -= userDepositorFees;

        // Update availableLiquidity accordingly
        availableLiquidity -= amountToWithdraw;

        emit Withdrawn(_msgSender(), amountToWithdraw);
    }

    // ========================== Borrow Function ==========================

    /**
     * @dev Allows users to borrow stablecoins by providing collateral.
     * Fees are split between admin fees and pool liquidity to benefit LP token holders.
     * @param amount Amount of stablecoins to borrow.
     */
    function borrow(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(address(depositShares) != address(0), "Pool not initialized");
        require(loans[msg.sender].amount == 0, "Already have an active loan");

        uint256 initialGas = gasleft(); // Record the initial amount of gas at the start

        uint256 collateralAmount = (amount * COLLATERALIZATION_RATIO) / 100;

        // Ensure available liquidity is enough to cover the full loan amount
        require(availableLiquidity >= amount, "Not enough stablecoins in the pool");

        // Transfer collateral from the borrower to the contract
        collateralToken.transferFrom(msg.sender, address(this), collateralAmount);

        // Calculate the gas fee dynamically an burn it
        uint256 gasFee = calculateGasFee(initialGas);
        token.burnFrom(_msgSender(), gasFee); // Collect gas fee

        // Store the loan details
        loans[msg.sender] = Loan({
            amount: amount,
            collateral: collateralAmount,
            borrowBlock: block.number,
            isFlashLoan: false,
            isRepaid: false
        });

        // Update pool metrics
        totalLoans += amount;
        availableLiquidity -= amount;

        // Transfer the full loan amount to the borrower
        stablecoin.transfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount, 0, collateralAmount, false);
    }

    // ========================== Repay Function ==========================

    /**
     * @dev Allows borrowers to repay their loans.
     * Fees are split between admin fees and pool liquidity to benefit LP token holders.
     * The remaining collateral is returned to the borrower.
     */
    function repay() external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.amount > 0, "No active loan");

        uint256 amountToRepay = loan.amount;

        // Transfer the full loan repayment amount from the borrower to the contract
        stablecoin.transferFrom(msg.sender, address(this), amountToRepay);

        // Calculate the fee based on the loan amount
        uint256 fee = (loan.amount * BORROW_FEE) / 10000; // 3% fee

        // Split the fee between admin and liquidity
        uint256 adminFee = fee / 2;
        uint256 liquidityFee = fee - adminFee;

        // Deduct the fee from the collateral being returned
        uint256 collateralToReturn = loan.collateral - fee;

        // Distribute the fee
        totalAdminFees += adminFee;
        availableLiquidity += liquidityFee;
        totalDepositorFees += liquidityFee; // Update totalDepositorFees

        // Return the collateral minus the fee to the borrower
        collateralToken.transfer(msg.sender, collateralToReturn);

        // Update pool metrics
        availableLiquidity += amountToRepay;
        totalLoans -= loan.amount;

        // Reset loan details
        loan.amount = 0;
        loan.collateral = 0;
        loan.isRepaid = true;

        emit Repaid(msg.sender, amountToRepay, collateralToReturn);
    }

    // ========================== Force Repayment Function ==========================

    /**
     * @dev Allows an admin to force repayment of a loan after the loan duration has expired.
     * The fee is split between admin fees and pool liquidity to benefit LP token holders.
     * @param borrower Address of the borrower whose loan is to be forcefully repaid.
     */
    function forceRepayment(address borrower) external onlyRole(ADMIN_ROLE) nonReentrant {
        Loan storage loan = loans[borrower];
        require(loan.amount > 0, "No active loan");
        require(block.number >= loan.borrowBlock + LOAN_DURATION_IN_BLOCKS, "Loan duration has not expired");

        uint256 totalRepayAmount = loan.amount; // Full loan amount to be repaid

        // Calculate the fee based on the loan amount
        uint256 collateralFee = (loan.amount * BORROW_FEE) / 10000; // 3% fee on the loan amount

        // Split the fee between admin and liquidity
        uint256 adminFee = collateralFee / 2;
        uint256 liquidityFee = collateralFee - adminFee;

        uint256 collateralToReturn = loan.collateral - collateralFee; // Collateral minus the fee

        // Lock the collateral before repayment to prevent front-running
        loan.collateral = 0;

        // Transfer the repayment amount from the admin to the contract
        stablecoin.transferFrom(msg.sender, address(this), totalRepayAmount);

        // Return the collateral minus the fee to the borrower
        collateralToken.transfer(borrower, collateralToReturn);

        // Update pool metrics
        availableLiquidity += totalRepayAmount + liquidityFee;
        totalLoans -= loan.amount;

        // Distribute the fee
        totalAdminFees += adminFee;
        totalDepositorFees += liquidityFee; // Update totalDepositorFees

        // Reset loan details
        loan.amount = 0;
        loan.isRepaid = true;

        emit ForcedRepayment(borrower, totalRepayAmount, collateralToReturn);
    }

    function calculateGasFee(uint256 initialGas) internal view returns (uint256) {
        uint256 gasUsed = initialGas - gasleft();  // Calculate gas used during function execution
        uint256 gasFee = gasUsed * tx.gasprice;    // Calculate fee based on gas used and current gas price
        return gasFee;
    }

    // ========================== Admin Functions ==========================

    /**
     * @dev Allows admins to withdraw accumulated fees.
     * @param amount Amount of fees to withdraw.
     */
    function withdrawFees(uint256 amount) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(amount <= totalAdminFees, "Insufficient admin fee balance");
        totalAdminFees -= amount;
        stablecoin.transfer(msg.sender, amount);

        emit FeesWithdrawn(msg.sender, amount);
    }

    function setLoanDurationInBlocks(uint256 newDuration) external onlyRole(ADMIN_ROLE) nonReentrant {
        LOAN_DURATION_IN_BLOCKS = newDuration;
    }

    function setCollateralizationRatio(uint256 newRatio) external onlyRole(ADMIN_ROLE) nonReentrant {
        COLLATERALIZATION_RATIO = newRatio;
    }

    // ========================== View Functions ==========================

    /**
     * @dev Returns the total stablecoin balance held by the contract.
     * @return balance Total stablecoin balance.
     */
    function getContractBalance() external view returns (uint256 balance) {
        balance = stablecoin.balanceOf(address(this));
    }

    /**
     * @dev Returns the LP token balance of a specific user.
     * @param _user Address of the user.
     * @return balance LP token balance of the user.
     */
    function getLPTokenBalance(address _user) external view returns (uint256 balance) {
        balance = depositShares.balanceOf(_user);
    }
}
