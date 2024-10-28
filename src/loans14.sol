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
    uint256 public LOAN_DURATION_IN_BLOCKS = 241920; // Approx. 14 days (assuming 5 sec blocks)
    uint256 public LOAN_DURATION_IN_BLOCKS_1= 1555200; // Approx 3 months
    uint256 public LOAN_DURATION_IN_BLOCKS_2 = 3110400; // Approx 6 month
    uint256 public LOAN_DURATION_IN_BLOCKS_3 = 6307200; // Approx 1 Year
    uint256 public APY_BPS = 550; // 5.5% APY in basis points
    uint256 public APY_BPS_1 = 650; // 6.5% APY in basis points
    uint256 public APY_BPS_2 = 700; // 7% APY in basis points
    uint256 public APY_BPS_3 = 900; // 9% APY in basis points    
    uint256 public BASIS_POINTS_DIVISOR = 10000;
    uint256 public BLOCKS_IN_A_YEAR = 6307200; // Total blocks in a year at 5-second block time
    uint256 public MINIMUM_FEE_BPS = 10; // Minimum fee of 0.10% in basis points



    // Pool Metrics
    uint256 public totalDeposits;        // Total stablecoins deposited by users
    uint256 public totalLoans;           // Total active loans
    uint256 public availableLiquidity;   // Liquidity available for borrowing
    uint256 public totalAdminFees;       // Total fees accumulated for admin
    uint256 public totalDepositorFees;   // Total fees accrued for depositors
    //uint256 public totalAdminCollateralFees;       // Total collateral fees accumulated for admin
    //uint256 public totalDepositorCollateralFees;   // Total collateral fees accrued for depositors


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
        uint256 loanDuration;  // Duration of loan
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
    function borrow(uint256 amount, uint256 loanLength) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(address(depositShares) != address(0), "Pool not initialized");
        require(loans[msg.sender].amount == 0, "Already have an active loan");
        require(loanLength == 1 || loanLength == 2 || loanLength == 3 || loanLength == 4, "Loan Duration invalid");
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
            loanDuration: loanLength,
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
        uint256 fee;
        uint256 applicableAPY;
        uint256 applicableLoanDuration;

        // Determine the applicable APY and loan duration
        if (loan.loanDuration == 1) {
            applicableAPY = APY_BPS;
            applicableLoanDuration = LOAN_DURATION_IN_BLOCKS;
        } else if (loan.loanDuration == 2) {
            applicableAPY = APY_BPS_1;
            applicableLoanDuration = LOAN_DURATION_IN_BLOCKS_1;
        } else if (loan.loanDuration == 3) {
            applicableAPY = APY_BPS_2;
            applicableLoanDuration = LOAN_DURATION_IN_BLOCKS_2;
        } else if (loan.loanDuration == 4) {
            applicableAPY = APY_BPS_3;
            applicableLoanDuration = LOAN_DURATION_IN_BLOCKS_3;
        } else {
            revert("Invalid duration");
        }

        // Calculate the number of blocks elapsed since the loan was taken
        uint256 blocksElapsed = block.number - loan.borrowBlock;

        // Cap the blocksElapsed at the applicableLoanDuration
        if (blocksElapsed > applicableLoanDuration) {
            blocksElapsed = applicableLoanDuration;
        }

        // Calculate the fee based on the actual time elapsed
        uint256 calculatedFee = (loan.amount * applicableAPY * blocksElapsed) / (BASIS_POINTS_DIVISOR * BLOCKS_IN_A_YEAR);

        // Calculate the minimum fee
        uint256 minimumFee = (loan.amount * MINIMUM_FEE_BPS) / BASIS_POINTS_DIVISOR;

        // Use the higher of the calculated fee and the minimum fee
        fee = calculatedFee > minimumFee ? calculatedFee : minimumFee;

        // Ensure fee does not exceed collateral
        require(fee <= loan.collateral, "Fee exceeds collateral amount");

        // Split the fee between admin and depositors
        uint256 adminFee = (fee * 5) / BASIS_POINTS_DIVISOR; // 0.05% to admin
        uint256 depositorFee = fee - adminFee;

        // Update fee metrics
        totalAdminFees += adminFee;
        totalDepositorFees += depositorFee;

        // Add depositor fee to available liquidity
        availableLiquidity += amountToRepay + depositorFee;

        // Return the collateral minus the fee to the borrower
        uint256 collateralToReturn = loan.collateral - fee;
        collateralToken.transfer(msg.sender, collateralToReturn);

        // Transfer the loan repayment amount from the borrower to the contract
        stablecoin.transferFrom(msg.sender, address(this), amountToRepay);

        // Update pool metrics
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
        

        uint256 amountToRepay = loan.amount;
        uint256 fee;

        if (loan.loanDuration == 1){
           require(block.number >= loan.borrowBlock + LOAN_DURATION_IN_BLOCKS, "Loan duration has not expired");
           fee = (loan.amount * APY_BPS * LOAN_DURATION_IN_BLOCKS) / (BASIS_POINTS_DIVISOR * BLOCKS_IN_A_YEAR); 
        } else if (loan.loanDuration == 2) {
           require(block.number >= loan.borrowBlock + LOAN_DURATION_IN_BLOCKS_1, "Loan duration has not expired"); 
           fee = (loan.amount * APY_BPS_1 * LOAN_DURATION_IN_BLOCKS_1) / (BASIS_POINTS_DIVISOR * BLOCKS_IN_A_YEAR);
        } else if (loan.loanDuration == 3) {
           require(block.number >= loan.borrowBlock + LOAN_DURATION_IN_BLOCKS_2, "Loan duration has not expired");
           fee = (loan.amount * APY_BPS_2 * LOAN_DURATION_IN_BLOCKS_2) / (BASIS_POINTS_DIVISOR * BLOCKS_IN_A_YEAR);
        } else if (loan.loanDuration == 4) {
           require(block.number >= loan.borrowBlock + LOAN_DURATION_IN_BLOCKS_3, "Loan duration has not expired");
           fee = (loan.amount * APY_BPS_3* LOAN_DURATION_IN_BLOCKS_3) / (BASIS_POINTS_DIVISOR * BLOCKS_IN_A_YEAR);
        }

        // Calculate the fee (interest) using blocks
        //fee = (loan.amount * APY_BPS * LOAN_DURATION_IN_BLOCKS) / (BASIS_POINTS_DIVISOR * BLOCKS_IN_A_YEAR);

        // Ensure fee does not exceed collateral
        require(fee <= loan.collateral, "Fee exceeds collateral amount");

        // Split the fee between admin and depositors
        uint256 adminFee = (fee * 5) / BASIS_POINTS_DIVISOR; // 0.05% to admin
        uint256 depositorFee = fee - adminFee;

        // Update fee metrics
        totalAdminFees += adminFee;
        totalDepositorFees += depositorFee;

        // Add depositor fee to available liquidity
        availableLiquidity += amountToRepay + depositorFee;

        // Return the collateral minus the fee to the borrower
        uint256 collateralToReturn = loan.collateral - fee;
        collateralToken.transfer(borrower, collateralToReturn);

        // Transfer the loan repayment amount from the admin to the contract
        stablecoin.transferFrom(msg.sender, address(this), amountToRepay);

        // Update pool metrics
        totalLoans -= loan.amount;

        // Reset loan details
        loan.amount = 0;
        loan.collateral = 0;
        loan.isRepaid = true;

        emit ForcedRepayment(borrower, amountToRepay, collateralToReturn);
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

    function setLoanDurationInBlocks(uint256 newDuration, uint256 newDuration1, uint256 newDuration2, uint256 newDuration3) external onlyRole(ADMIN_ROLE) nonReentrant {
        LOAN_DURATION_IN_BLOCKS = newDuration;
        LOAN_DURATION_IN_BLOCKS_1 = newDuration1;
        LOAN_DURATION_IN_BLOCKS_2 = newDuration2;
        LOAN_DURATION_IN_BLOCKS_3 = newDuration3;
    }

    function setCollateralizationRatio(uint256 newRatio) external onlyRole(ADMIN_ROLE) nonReentrant {
        COLLATERALIZATION_RATIO = newRatio;
    }

    function setBlocksInAYear(uint256 newBlocksInAYear) external onlyRole(ADMIN_ROLE) {
        BLOCKS_IN_A_YEAR = newBlocksInAYear;
    }

    function setMinimumFeeBPS(uint256 newMinimumFeeBPS) external onlyRole(ADMIN_ROLE) {
        MINIMUM_FEE_BPS = newMinimumFeeBPS;
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
