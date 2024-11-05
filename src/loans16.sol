// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin Contracts
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ITokenSwap.sol";
import "./interfaces/ITokenIface.sol";
import "./interfaces/IFlashLoanReceiver1.sol";

// Import Custom Contracts
import "./LPToken.sol";          // Custom ERC20 LP Token with Mint/Burn functionality
import "./EqualFiLPFactory.sol";     // Factory to create ERC20 tokens

/**
 * @title EqualFiLending
 * @dev A lending pool contract where users can deposit stablecoins, receive LP tokens, and borrow against collateral.
 *      Supports flash loans with a fixed fee.
 */
contract EqualFiLending is AccessControl, ReentrancyGuard {
    // ========================== State Variables ==========================

    // ERC20 Tokens
    IERC20 public stablecoin;             // Stablecoin used for deposits and loans
    IERC20 public collateralToken;        // Token used as collateral

    LPToken public depositShares;         // LP Token representing user shares in the pool

    TokenIface public token;              // Interface for burnFrom functionality
    EqualFiLPFactory public factory;      // Factory to create ERC20 tokens

    ITokenSwap public tokenSwap;          // External TokenSwap contract

    uint256 public COLLATERALIZATION_RATIO = 150; // 150% collateralization

    // Fees and Durations
    uint256 public LOAN_DURATION_IN_BLOCKS = 241920; // Approx. 14 days (assuming 5 sec blocks)
    uint256 public LOAN_DURATION_IN_BLOCKS_1 = 1555200; // Approx 3 months
    uint256 public LOAN_DURATION_IN_BLOCKS_2 = 3110400; // Approx 6 months
    uint256 public LOAN_DURATION_IN_BLOCKS_3 = 6307200; // Approx 1 Year
    uint256 public APY_BPS = 550; // 5.5% APY in basis points
    uint256 public APY_BPS_1 = 650; // 6.5% APY in basis points
    uint256 public APY_BPS_2 = 700; // 7% APY in basis points
    uint256 public APY_BPS_3 = 900; // 9% APY in basis points
    uint256 public BASIS_POINTS_DIVISOR = 10000;
    uint256 public BLOCKS_IN_A_YEAR = 6307200; // Total blocks in a year at 5-second block time
    uint256 public MINIMUM_FEE_BPS = 10; // Minimum fee of 0.10% in basis points
    uint256 public FLASHLOAN_FEE_BPS = 5; // Flash loan fee of 0.05% in basis points
    uint256 public depositCap;


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
        uint256 loanDuration;  // Duration of loan
    }

    // ========================== Mappings ==========================

    mapping(address => Loan) public loans; // Tracks loans per user

    // ========================== Events ==========================

    event PoolInitialized(address indexed initializer, address depositShareToken);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 fee, uint256 collateral);
    event Repaid(address indexed user, uint256 amount, uint256 collateralReturned, uint256 feePaid);
    event FeesWithdrawn(address indexed admin, uint256 amount);
    event ForcedRepayment(address indexed user, uint256 amount, uint256 collateralUsed);
    event FlashLoan(address indexed receiver, uint256 amount, uint256 fee);
    event TokensSwapped(address indexed user, address indexed inputToken, uint256 inputAmount, uint256 usdcReceived);

    // ========================== Constructor ==========================

    /**
     * @dev Initializes the contract by setting the stablecoin, collateral token, token interface, factory, and TokenSwap.
     * Grants the deployer the default admin and admin roles.
     * @param _stablecoin Address of the stablecoin used for deposits and loans.
     * @param _collateralToken Address of the token used as collateral.
     * @param _token Address of the TokenIface contract with burnFrom functionality.
     * @param _factory Address of the EqualFiLPFactory used to create LP tokens.
     * @param _tokenSwap Address of the TokenSwap contract.
     */
    constructor(
        IERC20 _stablecoin,
        IERC20 _collateralToken,
        TokenIface _token,
        EqualFiLPFactory _factory,
        ITokenSwap _tokenSwap
    ) {
        stablecoin = _stablecoin;
        collateralToken = _collateralToken;
        token = _token;
        factory = _factory;
        tokenSwap = _tokenSwap;

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
    function initializePool(string memory name, string memory symbol, address admin, uint256 depositCapAmount) external onlyRole(ADMIN_ROLE) {
        require(address(depositShares) == address(0), "Pool already initialized");

        depositCap = depositCapAmount;

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
     * @dev Allows users to deposit an approved token into the pool and receive LP tokens.
     * The approved token is swapped to USDC using the TokenSwap contract before depositing.
     * @param inputToken Address of the token the user wants to deposit.
     * @param amount Amount of the input token to deposit.
     * @param amountOutMinimum Minimum amount of USDC expected from the swap to protect against slippage.
     * @param deadline Unix timestamp after which the swap is no longer valid.
     */
    function swapDeposit(
        address inputToken,
        uint256 amount,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(address(depositShares) != address(0), "Pool not initialized");
        require(totalDeposits + amount <= depositCap, "Deposit cap exceeded");

        uint256 usdcAmount;

        if (inputToken == address(stablecoin)) {
            // Directly use the stablecoin
            usdcAmount = amount;
            // Transfer stablecoins from the user to the contract
            stablecoin.transferFrom(_msgSender(), address(this), amount);
        } else {
            // Swap the input token to USDC via the TokenSwap contract
            usdcAmount = tokenSwap.swapToUSDC(
                inputToken,
                amount,
                amountOutMinimum,
                deadline
            );
            require(usdcAmount > 0, "Swap failed");

            emit TokensSwapped(_msgSender(), inputToken, amount, usdcAmount);
        }

        require(totalDeposits + usdcAmount <= depositCap, "Deposit cap exceeded after swap");

        uint256 totalShares = depositShares.totalSupply();
        uint256 sharesToMint;

        if (totalShares == 0) {
            // First depositor sets the initial share value
            sharesToMint = usdcAmount;
        } else {
            // Mint LP tokens proportional to the deposit relative to pool's total assets
            uint256 poolTotalAssets = totalDeposits + totalDepositorFees; // Total pool assets excluding admin fees
            sharesToMint = (usdcAmount * totalShares) / poolTotalAssets;
        }

        // Mint LP tokens to the user
        depositShares.mint(_msgSender(), sharesToMint);

        // Update pool metrics
        totalDeposits += usdcAmount;
        availableLiquidity += usdcAmount;

        emit Deposited(_msgSender(), usdcAmount);
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

        // Update the totalDeposits and totalDepositorFees
        totalDeposits -= userDepositedAmount;
        totalDepositorFees -= userDepositorFees;

        // Update availableLiquidity accordingly
        availableLiquidity -= amountToWithdraw;

        // Transfer the stablecoin amount to the user
        stablecoin.transfer(_msgSender(), amountToWithdraw);

        emit Withdrawn(_msgSender(), amountToWithdraw);
    }

    // ========================== Borrow Function ==========================

    /**
     * @dev Allows users to borrow stablecoins by providing collateral.
     * Fees are split between admin fees and pool liquidity to benefit LP token holders.
     * @param amount Amount of stablecoins to borrow.
     * @param loanLength Duration identifier for the loan.
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

        // Calculate the gas fee dynamically and burn it
        uint256 gasFee = calculateGasFee(initialGas);
        token.burnFrom(_msgSender(), gasFee); // Collect gas fee

        // Store the loan details
        loans[msg.sender] = Loan({
            amount: amount,
            collateral: collateralAmount,
            borrowBlock: block.number,
            loanDuration: loanLength
        });

        // Update pool metrics
        totalLoans += amount;
        availableLiquidity -= amount;

        // Transfer the full loan amount to the borrower
        stablecoin.transfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount, 0, collateralAmount);
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
        delete loans[msg.sender];

        emit Repaid(msg.sender, amountToRepay, collateralToReturn, fee);
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

        require(
            block.number >= loan.borrowBlock + applicableLoanDuration,
            "Loan duration has not expired"
        );

        // Calculate the fee using the maximum loan duration
        fee = (loan.amount * applicableAPY * applicableLoanDuration) / (BASIS_POINTS_DIVISOR * BLOCKS_IN_A_YEAR);

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

        // Return the collateral minus the fee plus loan amount to the borrower
        // This makes it so liquidation is not required as well as no iteraction
        // from the user.  When the loan duration expires the user will have the
        // Collateral minus the loan amount and fee.
        uint256 collateralToReturn = loan.collateral - fee + loan.amount;
        collateralToken.transfer(borrower, collateralToReturn);

        // Update pool metrics
        totalLoans -= loan.amount;

        // Reset loan details
        delete loans[borrower];

        emit ForcedRepayment(borrower, amountToRepay, collateralToReturn);
    }

    // ========================== Flash Loan Function ==========================

    /**
     * @dev Allows users to take out a flash loan, which must be repaid within the same transaction.
     * A fixed percentage fee is charged.
     * @param receiverAddress The address of the contract implementing IFlashLoanReceiver.
     * @param amount The amount of stablecoins to borrow.
     * @param params Arbitrary data passed to the receiver's executeOperation function.
     */
    function flashLoan(
        address receiverAddress,
        uint256 amount,
        bytes calldata params
    ) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(amount <= availableLiquidity, "Not enough liquidity for flashloan");

        // Calculate the fee and total repayment amount
        uint256 fee = (amount * FLASHLOAN_FEE_BPS) / BASIS_POINTS_DIVISOR;
        uint256 repaymentAmount = amount + fee;

        // Record the initial balance of the contract
        uint256 balanceBefore = stablecoin.balanceOf(address(this));

        // Transfer the borrowed amount to the receiver
        stablecoin.transfer(receiverAddress, amount);

        // The receiver executes their custom logic
        IFlashLoanReceiver1(receiverAddress).executeOperation(amount, fee, params);

        // After the operation, calculate the amount repaid
        uint256 balanceAfter = stablecoin.balanceOf(address(this));
        uint256 amountRepaid = balanceAfter - balanceBefore;

        // Ensure that the borrower has repaid the loan plus fee
        require(
            amountRepaid >= repaymentAmount,
            "Flashloan not repaid"
        );

        // Distribute the fee between admin and depositors
        uint256 adminFee = (fee * 5) / BASIS_POINTS_DIVISOR; // 0.05% to admin
        uint256 depositorFee = fee - adminFee;

        totalAdminFees += adminFee;
        totalDepositorFees += depositorFee;

        // Update available liquidity with the depositor's portion of the fee
        availableLiquidity += depositorFee;

        emit FlashLoan(receiverAddress, amount, fee);
    }

    // ========================== Gas Fee Calculation ==========================

    /**
     * @dev Calculates the gas fee based on the gas used and the current gas price.
     * @param initialGas The initial amount of gas before executing the function.
     * @return gasFee The calculated gas fee.
     */
    function calculateGasFee(uint256 initialGas) internal view returns (uint256 gasFee) {
        uint256 gasUsed = initialGas - gasleft();  // Calculate gas used during function execution
        gasFee = gasUsed * tx.gasprice;            // Calculate fee based on gas used and current gas price
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

    /**
     * @dev Allows admins to set new loan durations in blocks.
     * @param newDuration Duration for loan type 1.
     * @param newDuration1 Duration for loan type 2.
     * @param newDuration2 Duration for loan type 3.
     * @param newDuration3 Duration for loan type 4.
     */
    function setLoanDurationInBlocks(
        uint256 newDuration,
        uint256 newDuration1,
        uint256 newDuration2,
        uint256 newDuration3
    ) external onlyRole(ADMIN_ROLE) nonReentrant {
        LOAN_DURATION_IN_BLOCKS = newDuration;
        LOAN_DURATION_IN_BLOCKS_1 = newDuration1;
        LOAN_DURATION_IN_BLOCKS_2 = newDuration2;
        LOAN_DURATION_IN_BLOCKS_3 = newDuration3;
    }

    /**
     * @dev Allows admins to set a new collateralization ratio.
     * @param newRatio The new collateralization ratio.
     */
    function setCollateralizationRatio(uint256 newRatio) external onlyRole(ADMIN_ROLE) nonReentrant {
        COLLATERALIZATION_RATIO = newRatio;
    }

    /**
     * @dev Allows admins to set a new number of blocks in a year.
     * @param newBlocksInAYear The new number of blocks in a year.
     */
    function setBlocksInAYear(uint256 newBlocksInAYear) external onlyRole(ADMIN_ROLE) {
        BLOCKS_IN_A_YEAR = newBlocksInAYear;
    }

    /**
     * @dev Allows admins to set a new minimum fee in basis points.
     * @param newMinimumFeeBPS The new minimum fee in basis points.
     */
    function setMinimumFeeBPS(uint256 newMinimumFeeBPS) external onlyRole(ADMIN_ROLE) {
        MINIMUM_FEE_BPS = newMinimumFeeBPS;
    }

    /**
     * @dev Allows admins to set a new flash loan fee in basis points.
     * @param newFlashLoanFeeBPS The new flash loan fee in basis points.
     */
    function setFlashLoanFeeBPS(uint256 newFlashLoanFeeBPS) external onlyRole(ADMIN_ROLE) {
        FLASHLOAN_FEE_BPS = newFlashLoanFeeBPS;
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
