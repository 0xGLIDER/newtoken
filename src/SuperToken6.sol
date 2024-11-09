// contracts/SuperToken5.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin Contracts
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import Libraries
import "./libraries/FeeCalculator3.sol"; // Updated FeeCalculator
import "./libraries/FeeDistributor.sol";
import "./libraries/PoolUtils.sol";

// Import Structs
import "./LiquidityPool.sol";
import "./Types.sol"; // Ensure Types is imported

// Interfaces
import "./interfaces/ITokenSwap.sol";
import "./interfaces/IEqualFiToken.sol";
import "./interfaces/IFlashLoanReceiver2.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// Import LPToken interface
import "./LPToken.sol";
import "./SuperTokenLPFactory.sol";

/**
 * @title SuperToken5
 * @dev A token representing a basket of underlying tokens with integrated lending and flash loan functionality.
 *      Similar to Uniswap V2 Liquidity Tokens, users can deposit multiple tokens to mint a single SuperToken.
 */
contract SuperToken5 is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20Metadata;
    using FeeDistributor for LiquidityPool;
    using PoolUtils for IERC20Metadata[];

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Constants
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant MINIMUM_FEE_BPS = 10; // 0.10%
    uint256 public FLASHLOAN_FEE_BPS; // Flash loan fee of 0.05% in basis points
    IERC721 public nft;

    // Enums
    enum LoanType {
        FOURTEEN_DAYS,
        THREE_MONTHS,
        SIX_MONTHS,
        ONE_YEAR
    }

    // Structs
    struct Loan {
        uint256 amount;
        uint256 collateral;
        uint256 borrowBlock;
        LoanType loanType;
        address tokenAddress;
        uint256 apyBps; // Stores the APY for this loan
    }

    // Mappings
    mapping(LoanType => Types.LoanTerms) public loanTerms; // Use Types.LoanTerms
    mapping(address => LiquidityPool) public liquidityPools;
    mapping(address => Loan) public loans;

    // State Variables
    IERC20Metadata[] public underlyingTokens;
    IEqualFiToken public EFItoken;
    uint256 public BLOCKS_IN_A_YEAR;
    uint256 public COLLATERALIZATION_RATIO; // e.g., 133 for 75% LTV

    // Required amounts per SuperToken for each underlying token
    uint256[] public requiredAmountsPerSuperToken;

    // LPToken contract
    LPToken public lpToken;

    // LPToken Factory
    SuperTokenLPFactory public lpFactory;

    // Events
    event PoolInitialized(address indexed initializer, address lpTokenAddress);
    event RequiredAmountsSet(uint256[] requiredAmounts);
    event LPTokenSet(address lpTokenAddress);
    event Deposit(address indexed user, uint256[] amounts, uint256 superAmount);
    event Redeem(address indexed user, uint256 superAmount, uint256[] amounts);
    event Borrowed(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 collateral
    );
    event Repaid(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 collateralReturned,
        uint256 feePaid
    );
    event ForcedRepayment(
        address indexed borrower,
        address indexed token,
        uint256 amount,
        uint256 collateralReturned,
        address indexed liquidator,
        uint256 liquidatorReward
    );
    event AdminFeesWithdrawn(
        address indexed admin,
        address indexed token,
        uint256 amount
    );
    event FlashLoan(
        address indexed receiver,
        address indexed token,
        uint256 amount,
        uint256 fee
    );
    event FeesClaimed(
        address indexed holder,
        address indexed token,
        uint256 amount
    );
    event IncentiveMinted(address indexed borrower, uint256 amount);

    constructor(
        IERC20Metadata[] memory _underlyingTokens,
        IEqualFiToken _token,
        SuperTokenLPFactory _lpFactory,
        uint256 _collateralizationRatio, // Pass 133 for 75% LTV
        uint256[] memory _requiredAmountsPerSuperToken
    ) {
        require(
            _underlyingTokens.length >= 1 && _underlyingTokens.length <= 10,
            "SuperToken5: invalid number of underlying tokens"
        );
        require(
            _requiredAmountsPerSuperToken.length == _underlyingTokens.length,
            "SuperToken5: required amounts length mismatch"
        );
        require(
            address(_lpFactory) != address(0),
            "SuperToken5: LPFactory address cannot be zero"
        );

        // Initialize AccessControl
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        for (uint256 i = 0; i < _underlyingTokens.length; i++) {
            address tokenAddr = address(_underlyingTokens[i]);
            liquidityPools[tokenAddr] = LiquidityPool({
                token: _underlyingTokens[i],
                totalDeposits: 0,
                totalBorrowed: 0,
                totalFees: 0,
                adminFees: 0,
                holderFees: 0
            });
            underlyingTokens.push(_underlyingTokens[i]);
            requiredAmountsPerSuperToken.push(_requiredAmountsPerSuperToken[i]); // Store Required Amounts
        }

        EFItoken = _token;

        // Initialize COLLATERALIZATION_RATIO
        COLLATERALIZATION_RATIO = _collateralizationRatio; // e.g., 133 for 75% LTV

        // Initialize loan terms with separate APY rates
        // Example APYs: depositors at 5.5%, 6.5%, 7%, 9%
        // Non-depositors at 4.5%, 5.5%, 6%, 8%
        loanTerms[LoanType.FOURTEEN_DAYS] = Types.LoanTerms(241920, 550, 450); // 14 days, 5.5% APY depositor, 4.5% non-depositor
        loanTerms[LoanType.THREE_MONTHS] = Types.LoanTerms(1555200, 650, 550); // 3 months, 6.5% APY depositor, 5.5% non-depositor
        loanTerms[LoanType.SIX_MONTHS] = Types.LoanTerms(3110400, 700, 600); // 6 months, 7% APY depositor, 6% non-depositor
        loanTerms[LoanType.ONE_YEAR] = Types.LoanTerms(6307200, 900, 800); // 1 year, 9% APY depositor, 8% non-depositor

        BLOCKS_IN_A_YEAR = 6307200; // Total blocks in a year at 5-second block time

        // Set flash loan fee
        FLASHLOAN_FEE_BPS = 5; // 0.05%

        // Set LPToken factory
        lpFactory = _lpFactory;

        emit PoolInitialized(msg.sender, address(0)); // LPToken not set yet
        emit RequiredAmountsSet(_requiredAmountsPerSuperToken);
    }

    // ========================== Initialize Pool Function ==========================

    /**
     * @dev Initializes the pool by creating the LPToken via the LPFactory.
     *      Only callable once by an admin.
     * @param name Name of the LPToken.
     * @param symbol Symbol of the LPToken.
     * @param adminAddress Address to be granted DEFAULT_ADMIN_ROLE on LPToken.
     */
    function initializePool(
        string memory name,
        string memory symbol,
        address adminAddress,
        IERC721 _nft
    ) external onlyRole(ADMIN_ROLE) {
        require(
            address(lpToken) == address(0),
            "SuperToken5: LPToken already set"
        );
        require(
            adminAddress != address(0),
            "SuperToken5: admin address cannot be zero"
        );

        nft = _nft;

        // Use the LPFactory to create the LPToken
        lpToken = lpFactory.createLPToken(name, symbol, address(this));
        require(
            address(lpToken) != address(0),
            "SuperToken5: LPToken creation failed"
        );

        // Grant roles to SuperToken5
        lpToken.grantRole(lpToken.MINTER_ROLE(), address(this));
        lpToken.grantRole(lpToken.BURNER_ROLE(), address(this));

        // Grant DEFAULT_ADMIN_ROLE to the specified admin
        lpToken.grantRole(lpToken.DEFAULT_ADMIN_ROLE(), adminAddress);

        emit LPTokenSet(address(lpToken));
        emit PoolInitialized(msg.sender, address(lpToken));
    }

    // ========================== Deposit Function ==========================

    /**
     * @dev Allows users to deposit multiple underlying tokens and mint SuperTokens based on specified ratios.
     * @param superAmount The amount of SuperTokens to mint.
     */
    function deposit(uint256 superAmount) external nonReentrant {
        //require(nft.balanceOf(_msgSender()) > 0, "Staking: No NFT balance");
        require(address(lpToken) != address(0), "SuperToken5: LPToken not set");
        require(
            requiredAmountsPerSuperToken.length == underlyingTokens.length,
            "SuperToken5: required amounts length mismatch"
        );
        require(
            superAmount > 1e18,
            "SuperToken5: superAmount must be greater than 1 token"
        );

        uint8 decimals = lpToken.decimals();
        uint256 unitLPToken = 10**uint256(decimals);

        uint256[] memory requiredDeposits = new uint256[](
            underlyingTokens.length
        );

        for (uint256 i = 0; i < underlyingTokens.length; i++) {
            // Calculate required amount for each token
            requiredDeposits[i] =
                (superAmount * requiredAmountsPerSuperToken[i]) /
                unitLPToken;

            IERC20Metadata tokenContract = underlyingTokens[i];
            tokenContract.safeTransferFrom(
                msg.sender,
                address(this),
                requiredDeposits[i]
            );
            liquidityPools[address(tokenContract)]
                .totalDeposits += requiredDeposits[i];
        }

        // Mint SuperTokens via LPToken contract
        lpToken.mint(msg.sender, superAmount);

        emit Deposit(msg.sender, requiredDeposits, superAmount);
    }

    // ========================== Redeem Function ==========================

    function redeem(uint256 superAmount) external nonReentrant {
        require(superAmount > 0, "SuperToken5: zero redeem amount");
        require(address(lpToken) != address(0), "SuperToken5: LPToken not set");

        uint256 initialHolderBal = lpToken.balanceOf(msg.sender);
        require(
            initialHolderBal >= superAmount,
            "SuperToken5: insufficient LP token balance"
        );

        uint256 supply = lpToken.totalSupply();
        uint256 share = (superAmount * 1e18) / supply;

        // Burn LPTokens
        lpToken.burnFrom(msg.sender, superAmount);

        uint256[] memory amountsToReturn = new uint256[](
            underlyingTokens.length
        );

        for (uint256 i = 0; i < underlyingTokens.length; i++) {
            IERC20Metadata tokenContract = underlyingTokens[i];
            address tokenAddr = address(tokenContract);
            LiquidityPool storage pool = liquidityPools[tokenAddr];

            // Calculate available deposits
            uint256 availableDeposits = pool.totalDeposits - pool.totalBorrowed;

            // Calculate deposit amount to return
            uint256 depositAmt = (availableDeposits * share) / 1e18;
            require(
                depositAmt <= availableDeposits,
                "SuperToken5: insufficient available deposits"
            );
            pool.totalDeposits -= depositAmt;

            // Calculate fee amount to return
            uint256 feeAmt = (pool.holderFees * share) / 1e18;
            if (feeAmt > 0) {
                pool.holderFees -= feeAmt;
                emit FeesClaimed(msg.sender, tokenAddr, feeAmt);
            }

            // Transfer combined amount
            uint256 totalAmt = depositAmt + feeAmt;
            require(
                tokenContract.balanceOf(address(this)) >= totalAmt,
                "SuperToken5: insufficient contract balance"
            );
            tokenContract.safeTransfer(msg.sender, totalAmt);

            amountsToReturn[i] = totalAmt;
        }

        emit Redeem(msg.sender, superAmount, amountsToReturn);
    }

    // ========================== Borrow Function ==========================

    /**
    * @dev Allows users to borrow a specified amount of an underlying token.
    *      Depositors can borrow up to 75% LTV based on their share in the pool without additional collateral.
    *      Non-Depositors must provide collateral to meet the 75% LTV requirement.
    * @param tokenAddress The address of the underlying token to borrow.
    * @param amount The amount of the underlying token to borrow.
    * @param loanType The type of loan being taken.
    */
    function borrow(address tokenAddress, uint256 amount, LoanType loanType) external nonReentrant {
        require(amount > 0, "SuperToken5: zero borrow amount");
        require(
            loans[msg.sender].amount == 0,
            "SuperToken5: active loan exists"
        );
        require(address(lpToken) != address(0), "SuperToken5: LPToken not set");

        LiquidityPool storage pool = liquidityPools[tokenAddress];
        require(address(pool.token) != address(0), "SuperToken5: invalid token");
        
        uint256 userLPBalance = lpToken.balanceOf(msg.sender);
        bool isDepositor = userLPBalance > 0;
        uint256 maxBorrow = 0;
        uint256 collateral = 0;
        uint256 apyBps = isDepositor ? loanTerms[loanType].apyBps : loanTerms[loanType].apyBpsNonDepositor;

        if (isDepositor) {
            // **Depositor Path: Borrow based on pool share**

            // Calculate user's share in the pool (scaled by 1e18 for precision)
            uint256 userShare = (userLPBalance * 1e18) / lpToken.totalSupply();

            // Calculate available liquidity for the token
            uint256 availableLiquidity = pool.totalDeposits - pool.totalBorrowed;

            // Calculate maximum borrowable amount based on 75% LTV
            maxBorrow = (userShare * availableLiquidity * 75) / (100 * 1e18);

            require(
                amount <= maxBorrow,
                "SuperToken5: borrow amount exceeds 75% LTV based on pool share"
            );

            // **No additional collateral required for depositors**
            collateral = 0;
        } else {
            // **Non-Depositor Path: Borrow by providing collateral**

            // Calculate collateral based on the collateralization ratio (133% for 75% LTV)
            collateral = (amount * COLLATERALIZATION_RATIO) / 100;

            // **Ensure the user has approved the contract to transfer collateral**
            uint256 allowance = pool.token.allowance(msg.sender, address(this));
            require(allowance >= collateral, "SuperToken5: insufficient allowance for collateral");

            // Transfer collateral from borrower to the contract
            pool.token.safeTransferFrom(msg.sender, address(this), collateral);

            // **Optionally, treat collateral as part of pool's deposits**
            pool.totalDeposits += collateral;
        }

        // Transfer the borrowed amount to the borrower
        pool.token.safeTransfer(msg.sender, amount);

        // Update the total borrowed amount
        pool.totalBorrowed += amount;

        // Record the loan details with the appropriate APY
        loans[msg.sender] = Loan({
            amount: amount,
            collateral: collateral,
            borrowBlock: block.number,
            loanType: loanType,
            tokenAddress: tokenAddress,
            apyBps: apyBps
        });

        // Calculate the gas fee dynamically and burn it
        uint256 initialGas = gasleft();
        uint256 gasFee = calculateGasFee(initialGas);
        EFItoken.burnFrom(msg.sender, gasFee); // Collect gas fee

        // Emit the Borrowed event with relevant details
        emit Borrowed(msg.sender, tokenAddress, amount, collateral);
    }

    // ========================== Repay Function ==========================

    function repay() external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.amount > 0, "SuperToken5: no active loan");

        LiquidityPool storage pool = liquidityPools[loan.tokenAddress];
        require(
            address(pool.token) != address(0),
            "SuperToken5: invalid token"
        );

        uint256 currentBlock = block.number;
        uint256 fee = calculateFee(loan, currentBlock);
        uint256 totalDue = loan.amount + fee;

        if (loan.collateral > 0) {
            // **Loans with Collateral:**
            require(
                loan.collateral >= totalDue,
                "SuperToken5: fee exceeds collateral"
            );

            // Transfer the repayment amount from the borrower to the contract
            pool.token.safeTransferFrom(msg.sender, address(this), totalDue);

            // Deduct loan amount and fee from collateral
            uint256 netCollateralReturn = loan.collateral - fee;

            // Update state variables
            pool.totalBorrowed -= loan.amount;
            pool.totalFees += fee;
            pool.distributeFees(fee);

            // Return net collateral to borrower
            if (netCollateralReturn > 0) {
                pool.token.safeTransfer(msg.sender, netCollateralReturn);
            }
        } else {
            // **Depositor Loans (No Collateral):**
            // Only require repayment of the loan amount plus fee
            pool.token.safeTransferFrom(msg.sender, address(this), totalDue);

            // Update state variables
            pool.totalBorrowed -= loan.amount;
            pool.totalFees += fee;
            pool.distributeFees(fee);
            // No collateral to return
        }

        // **Mint EFItoken as an incentive**
        uint256 incentiveAmount = calculateIncentive(fee);
        EFItoken.mintTo(msg.sender, incentiveAmount);

        // Delete loan record
        delete loans[msg.sender];

        // Emit Repaid event
        emit Repaid(
            msg.sender,
            loan.tokenAddress,
            loan.amount,
            loan.collateral > 0 ? (loan.collateral - fee) : 0,
            fee
        );

        // Emit Incentive Minted event
        emit IncentiveMinted(msg.sender, incentiveAmount);
    }

    // ========================== Liquidate Function ==========================

    /**
     * @dev Allows any user to liquidate a borrower's loan after the loan duration has expired.
     *      The liquidator receives a 5% reward from the collateral.
     * @param borrower The address of the borrower whose loan is to be liquidated.
     */
    function liquidate(address borrower) external nonReentrant {
        Loan storage loan = loans[borrower];
        require(loan.amount > 0, "SuperToken5: no active loan");

        LiquidityPool storage pool = liquidityPools[loan.tokenAddress];
        require(
            address(pool.token) != address(0),
            "SuperToken5: invalid token"
        );

        LoanType loanType = loan.loanType;
        Types.LoanTerms memory terms = loanTerms[loanType];

        require(
            block.number >= loan.borrowBlock + terms.durationInBlocks,
            "SuperToken5: loan not expired"
        );

        uint256 currentBlock = block.number;
        uint256 fee = calculateFee(loan, currentBlock);
        require(fee <= loan.collateral, "SuperToken5: fee exceeds collateral");

        pool.totalBorrowed -= loan.amount;
        pool.totalFees += fee;

        // Distribute the collected fee
        pool.distributeFees(fee);

        // Calculate liquidator's reward (5% of collateral)
        uint256 liquidatorReward = (loan.collateral * 5) / 100;
        uint256 borrowerCollateral = loan.collateral - fee - liquidatorReward;

        // Transfer liquidator's reward to the caller
        pool.token.safeTransfer(msg.sender, liquidatorReward);

        // Transfer remaining collateral to the borrower
        if (borrowerCollateral > 0) {
            pool.token.safeTransfer(borrower, borrowerCollateral);
        }

        // Delete loan record
        delete loans[borrower];

        emit ForcedRepayment(
            borrower,
            loan.tokenAddress,
            loan.amount,
            borrowerCollateral,
            msg.sender,
            liquidatorReward
        );
    }

    // ========================== Flash Loan Function ==========================

    /**
     * @dev Allows users to perform a flash loan for a specific underlying token.
     *      The loan plus fee must be repaid within the same transaction.
     * @param tokenAddress The address of the underlying token to borrow.
     * @param amount The amount of the underlying token to borrow.
     * @param receiver The contract address that will receive the funds and execute the operation.
     * @param params Arbitrary data passed to the receiver's executeOperation function.
     */
    function flashLoan(
        address tokenAddress,
        uint256 amount,
        address receiver,
        bytes calldata params
    ) external nonReentrant {
        require(address(lpToken) != address(0), "SuperToken5: LPToken not set");
        require(amount > 0, "SuperToken5: zero flash loan amount");

        LiquidityPool storage pool = liquidityPools[tokenAddress];
        require(
            address(pool.token) != address(0),
            "SuperToken5: invalid token"
        );
        require(
            pool.totalDeposits - pool.totalBorrowed >= amount,
            "SuperToken5: insufficient liquidity"
        );

        uint256 fee = (amount * FLASHLOAN_FEE_BPS) / BASIS_POINTS_DIVISOR;
        //uint256 repaymentAmount = amount + fee;

        uint256 balanceBefore = pool.token.balanceOf(address(this));

        pool.token.safeTransfer(receiver, amount);

        IFlashLoanReceiver2(receiver).executeOperation(
            tokenAddress,
            amount,
            fee,
            msg.sender,
            params
        );

        uint256 balanceAfter = pool.token.balanceOf(address(this));
        require(
            balanceAfter >= balanceBefore + fee,
            "SuperToken5: flash loan not repaid"
        );

        // Now that the fee has been repaid, account for it
        pool.totalFees += fee;
        pool.distributeFees(fee);

        emit FlashLoan(receiver, tokenAddress, amount, fee);
    }

    // ========================== Admin Functions ==========================

    /**
     * @dev Allows admins to withdraw accumulated admin fees for a specific token.
     * @param tokenAddress The address of the underlying token from which to withdraw admin fees.
     */
    function withdrawAdminFees(address tokenAddress)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        LiquidityPool storage pool = liquidityPools[tokenAddress];
        require(
            address(pool.token) != address(0),
            "SuperToken5: invalid token"
        );
        require(pool.adminFees > 0, "SuperToken5: no admin fees");

        uint256 amt = pool.adminFees;
        pool.adminFees = 0;
        pool.token.safeTransfer(msg.sender, amt);

        emit AdminFeesWithdrawn(msg.sender, tokenAddress, amt);
    }

    /**
     * @dev Allows admins to set new loan parameters.
     * @param loanType The type of loan to set parameters for.
     * @param durationInBlocks The duration of the loan in blocks.
     * @param apyBps The APY of the loan in basis points for depositors.
     * @param apyBpsNonDepositor The APY of the loan in basis points for non-depositors.
     */
    function setLoanParameters(
        LoanType loanType,
        uint256 durationInBlocks,
        uint256 apyBps,
        uint256 apyBpsNonDepositor
    ) external onlyRole(ADMIN_ROLE) {
        require(durationInBlocks > 0, "SuperToken5: duration must be greater than zero");
        require(apyBps > 0, "SuperToken5: APY must be greater than zero");
        require(apyBpsNonDepositor > 0, "SuperToken5: Non-depositor APY must be greater than zero");
        loanTerms[loanType] = Types.LoanTerms(durationInBlocks, apyBps, apyBpsNonDepositor);
    }

    /**
     * @dev Allows admins to set a new flash loan fee in basis points.
     * @param newFeeBps The new flash loan fee in basis points.
     */
    function setFlashLoanFeeBPS(uint256 newFeeBps)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(newFeeBps <= BASIS_POINTS_DIVISOR, "SuperToken5: invalid fee");
        FLASHLOAN_FEE_BPS = newFeeBps;
        // Optionally emit an event
    }

    /**
     * @dev Allows admins to set a new collateralization ratio.
     *      Ensures the ratio maintains at least a 75% LTV.
     * @param newRatio The new collateralization ratio (e.g., 133 for 75% LTV).
     */
    function setCollateralizationRatio(uint256 newRatio) external onlyRole(ADMIN_ROLE) {
        require(newRatio >= 133, "SuperToken5: ratio too low, LTV exceeds 75%");
        COLLATERALIZATION_RATIO = newRatio;
    }

    // ========================== View Functions ==========================

    /**
     * @dev Returns the loan details of a borrower.
     * @param borrower The address of the borrower.
     */
    function getLoanDetails(address borrower)
        external
        view
        returns (Loan memory)
    {
        return loans[borrower];
    }

    /**
     * @dev Returns the total available liquidity across all underlying tokens.
     */
    function totalAvailableLiquidity() external view returns (uint256 total) {
        for (uint256 i = 0; i < underlyingTokens.length; i++) {
            LiquidityPool storage pool = liquidityPools[
                address(underlyingTokens[i])
            ];
            total += (pool.totalDeposits - pool.totalBorrowed);
        }
    }

    /**
     * @dev Returns the total deposits across all pools.
     */
    function getTotalPoolDeposits() public view returns (uint256 total) {
        total = underlyingTokens.getTotalPoolDeposits(liquidityPools);
    }

    /**
     * @dev Returns the array of underlying token addresses.
     */
    function getUnderlyingTokens()
        public
        view
        returns (address[] memory tokens)
    {
        tokens = underlyingTokens.getUnderlyingTokens();
    }

    // ========================== Internal Functions ==========================

    /**
     * @dev Internal function to distribute fees using the FeeDistributor library.
     * @param pool The liquidity pool.
     * @param fee The fee amount to distribute.
     */
    function _distributeFees(LiquidityPool storage pool, uint256 fee) internal {
        pool.distributeFees(fee);
    }

    /**
     * @dev Internal function to calculate fees using the FeeCalculator2 library.
     * @param loan The loan details.
     * @param currentBlock The current block number.
     * @return fee The calculated fee.
     */
    function calculateFee(
        Loan storage loan,
        uint256 currentBlock
    )
        internal
        view
        returns (uint256 fee)
    {
        /**Types.LoanTerms memory terms = loanTerms[loan.loanType];
        fee = FeeCalculator2.calculateTimeBasedFee(
            loan.amount,
            loan.borrowBlock,
            currentBlock,
            BLOCKS_IN_A_YEAR,
            MINIMUM_FEE_BPS,
            BASIS_POINTS_DIVISOR,
            loan.apyBps // Pass the specific APY for this loan
        );**/
    }

    // ========================== Gas Fee Calculation ==========================

    /**
     * @dev Calculates the gas fee based on the gas used and the current gas price.
     * @param initialGas The initial amount of gas before executing the function.
     * @return gasFee The calculated gas fee.
     */
    function calculateGasFee(uint256 initialGas)
        internal
        view
        returns (uint256 gasFee)
    {
        uint256 gasUsed = initialGas - gasleft(); // Calculate gas used during function execution
        gasFee = gasUsed * tx.gasprice; // Calculate fee based on gas used and current gas price
    }

    /**
     * @dev Calculates the required amounts of underlying tokens needed to mint a specified amount of SuperTokens.
     * @param superAmount The amount of SuperTokens the user wants to mint.
     * @return requiredDeposits An array containing the required amounts for each underlying token.
     */
    function calculateRequiredDeposits(uint256 superAmount)
        public
        view
        returns (uint256[] memory requiredDeposits)
    {
        require(address(lpToken) != address(0), "SuperToken5: LPToken not set");
        require(
            requiredAmountsPerSuperToken.length == underlyingTokens.length,
            "SuperToken5: required amounts length mismatch"
        );
        require(
            superAmount > 0,
            "SuperToken5: superAmount must be greater than zero"
        );

        uint8 decimals = lpToken.decimals();
        uint256 unitLPToken = 10**uint256(decimals);

        requiredDeposits = new uint256[](underlyingTokens.length);

        for (uint256 i = 0; i < underlyingTokens.length; i++) {
            // Calculate required amount for each token
            requiredDeposits[i] =
                (superAmount * requiredAmountsPerSuperToken[i]) /
                unitLPToken;
        }

        return requiredDeposits;
    }

    // ========================== Incentive Calculation ==========================

    function calculateIncentive(uint256 fee) internal pure returns (uint256 incentive) {
        // Example: Mint 1% of the fee as incentive
        incentive = (fee * 100) / BASIS_POINTS_DIVISOR; // 1% incentive
    }

    // ========================== Fallback and Receive ==========================

    fallback() external payable {
        revert("SuperToken5: cannot accept ETH");
    }

    receive() external payable {
        revert("SuperToken5: cannot accept ETH");
    }
}
