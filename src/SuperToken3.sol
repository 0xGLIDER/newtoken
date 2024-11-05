// contracts/SuperToken2.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin Contracts
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import Libraries
import "./libraries/FeeCalculator.sol";
import "./libraries/FeeDistributor.sol";
import "./libraries/PoolUtils.sol";

// Import Structs
import "./LiquidityPool.sol";
import "./Types.sol";

// Interfaces
import "./interfaces/ITokenSwap.sol";
import "./interfaces/IEqualFiToken.sol";
import "./interfaces/IFlashLoanReceiver2.sol";

// Import LPToken interface
import "./LPToken.sol";

/**
 * @title SuperToken2
 * @dev A token representing a basket of underlying tokens with integrated lending and flash loan functionality.
 *      Similar to Uniswap V2 Liquidity Tokens, users can deposit multiple tokens to mint a single SuperToken.
 */
contract SuperToken3 is Initializable, ReentrancyGuardUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20Metadata;
    using FeeCalculator for LoanTerms;
    using FeeDistributor for LiquidityPool;
    using PoolUtils for IERC20Metadata[];

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Constants
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant MINIMUM_FEE_BPS = 10; // 0.10%
    uint256 public FLASHLOAN_FEE_BPS;            // Flash loan fee of 0.05% in basis points

    // Enums
    enum LoanType { FOURTEEN_DAYS, THREE_MONTHS, SIX_MONTHS, ONE_YEAR }

    // Structs
    struct Loan {
        uint256 amount;
        uint256 collateral;
        uint256 borrowBlock;
        LoanType loanType;
        address tokenAddress;
    }

    // Mappings
    mapping(LoanType => LoanTerms) public loanTerms;
    mapping(address => LiquidityPool) public liquidityPools;
    mapping(address => Loan) public loans;

    // State Variables
    IERC20Metadata[] public underlyingTokens;
    IEqualFiToken public token;
    uint256 public BLOCKS_IN_A_YEAR;
    uint256 public COLLATERALIZATION_RATIO; // e.g., 150 for 150%

    // **New State Variable**: Required amounts per SuperToken for each underlying token
    uint256[] public requiredAmountsPerSuperToken;

    // **New State Variable**: LPToken contract
    LPToken public lpToken;

    // Events
    event Deposit(address indexed user, uint256[] amounts, uint256 superAmount);
    event Redeem(address indexed user, uint256 superAmount, uint256[] amounts);
    event Borrowed(address indexed user, address indexed token, uint256 amount, uint256 collateral);
    event Repaid(address indexed user, address indexed token, uint256 amount, uint256 collateralReturned, uint256 feePaid);
    event ForcedRepayment(address indexed user, address indexed token, uint256 amount, uint256 collateralUsed);
    event AdminFeesWithdrawn(address indexed admin, address indexed token, uint256 amount);
    event FlashLoan(address indexed receiver, address indexed token, uint256 amount, uint256 fee);
    event FeesClaimed(address indexed holder, address indexed token, uint256 amount);
    event PoolInitialized(address indexed initializer, address[] tokens);
    event RequiredAmountsSet(uint256[] requiredAmounts); // **New Event**
    event LPTokenSet(address lpTokenAddress); // **New Event**

    // Initialization
    function initialize(
        IERC20Metadata[] memory _underlyingTokens,
        IEqualFiToken _token,
        address admin,
        uint256 _collateralizationRatio, // New parameter
        uint256[] memory _requiredAmountsPerSuperToken, // **New Parameter**
        address _lpTokenAddress // **New Parameter**
    ) public initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();

        require(_underlyingTokens.length >= 2 && _underlyingTokens.length <= 10, "SuperToken2: invalid number of underlying tokens");
        require(_requiredAmountsPerSuperToken.length == _underlyingTokens.length, "SuperToken2: required amounts length mismatch");

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
            requiredAmountsPerSuperToken.push(_requiredAmountsPerSuperToken[i]); // **Store Required Amounts**
        }

        token = _token;

        // Initialize COLLATERALIZATION_RATIO
        COLLATERALIZATION_RATIO = _collateralizationRatio; // e.g., 150 for 150%

        // Initialize loan terms
        loanTerms[LoanType.FOURTEEN_DAYS] = LoanTerms(241920, 550);    // 14 days, 5.5% APY
        loanTerms[LoanType.THREE_MONTHS] = LoanTerms(1555200, 650);  // 3 months, 6.5% APY
        loanTerms[LoanType.SIX_MONTHS] = LoanTerms(3110400, 700);    // 6 months, 7% APY
        loanTerms[LoanType.ONE_YEAR] = LoanTerms(6307200, 900);      // 1 year, 9% APY

        BLOCKS_IN_A_YEAR = 6307200; // Total blocks in a year at 5-second block time

        // Set flash loan fee
        FLASHLOAN_FEE_BPS = 5; // 0.05%

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        // Set LPToken contract
        lpToken = LPToken(_lpTokenAddress);
        require(address(lpToken) != address(0), "SuperToken2: LPToken address cannot be zero");

        emit PoolInitialized(msg.sender, getUnderlyingTokens());
        emit RequiredAmountsSet(_requiredAmountsPerSuperToken); // **Emit Event**
        emit LPTokenSet(_lpTokenAddress); // **Emit Event**
    }

    // ========================== Deposit Function ==========================

    /**
     * @dev Allows users to deposit multiple underlying tokens and mint SuperTokens based on specified ratios.
     * @param amounts Array of amounts for each underlying token to deposit.
     */
    function deposit(uint256[] calldata amounts) external nonReentrant {
        require(amounts.length == underlyingTokens.length, "SuperToken2: amounts length mismatch");
        require(requiredAmountsPerSuperToken.length == underlyingTokens.length, "SuperToken2: required amounts length mismatch");

        uint256 mintAmount = type(uint256).max; // Initialize to max for min calculation

        // Determine the number of SuperTokens to mint based on the smallest ratio
        for (uint256 i = 0; i < underlyingTokens.length; i++) {
            require(amounts[i] >= requiredAmountsPerSuperToken[i], "SuperToken2: insufficient deposit for token");
            uint256 possibleMint = amounts[i] / requiredAmountsPerSuperToken[i];
            if (possibleMint < mintAmount) {
                mintAmount = possibleMint;
            }
        }

        require(mintAmount > 0, "SuperToken2: deposit amounts too low to mint any SuperTokens");

        // Calculate total required amounts based on mintAmount
        uint256[] memory requiredDeposits = new uint256[](underlyingTokens.length);
        for (uint256 i = 0; i < underlyingTokens.length; i++) {
            requiredDeposits[i] = requiredAmountsPerSuperToken[i] * mintAmount;
            IERC20Metadata tokenContract = underlyingTokens[i];
            tokenContract.safeTransferFrom(msg.sender, address(this), requiredDeposits[i]);
            liquidityPools[address(tokenContract)].totalDeposits += requiredDeposits[i];
        }

        // Mint SuperTokens via LPToken contract
        uint8 decimals = lpToken.decimals();
        uint256 superAmount = mintAmount * (10 ** decimals); // Mint with decimals consideration
        lpToken.mint(msg.sender, superAmount);

        emit Deposit(msg.sender, requiredDeposits, superAmount);
    }

    // ========================== Redeem Function ==========================

    function redeem(uint256 superAmount) external nonReentrant {
        require(superAmount > 0, "SuperToken2: zero redeem amount");
        uint256 initialHolderBal = lpToken.balanceOf(msg.sender);
        require(initialHolderBal >= superAmount, "SuperToken2: insufficient LP token balance");

        uint256 supply = lpToken.totalSupply();
        uint256 share = (superAmount * 1e18) / supply;

        // Burn LPTokens
        lpToken.burnFrom(msg.sender, superAmount);

        uint256[] memory amountsToReturn = new uint256[](underlyingTokens.length);

        for (uint256 i = 0; i < underlyingTokens.length; i++) {
            IERC20Metadata tokenContract = underlyingTokens[i];
            address tokenAddr = address(tokenContract);
            LiquidityPool storage pool = liquidityPools[tokenAddr];

            // Calculate available deposits
            uint256 availableDeposits = pool.totalDeposits - pool.totalBorrowed;

            // Calculate deposit amount to return
            uint256 depositAmt = (availableDeposits * share) / 1e18;
            require(depositAmt <= availableDeposits, "SuperToken2: insufficient available deposits");
            pool.totalDeposits -= depositAmt;

            // Calculate fee amount to return
            uint256 feeAmt = (pool.holderFees * share) / 1e18;
            if (feeAmt > 0) {
                pool.holderFees -= feeAmt;
                emit FeesClaimed(msg.sender, tokenAddr, feeAmt);
            }

            // Transfer combined amount
            uint256 totalAmt = depositAmt + feeAmt;
            require(tokenContract.balanceOf(address(this)) >= totalAmt, "SuperToken2: insufficient contract balance");
            tokenContract.safeTransfer(msg.sender, totalAmt);

            amountsToReturn[i] = totalAmt;
        }

        emit Redeem(msg.sender, superAmount, amountsToReturn);
    }




    // ========================== Borrow Function ==========================

    function borrow(address tokenAddress, uint256 amount, LoanType loanType) external nonReentrant {
        require(amount > 0, "SuperToken2: zero borrow amount");
        require(loans[msg.sender].amount == 0, "SuperToken2: active loan exists");

        LiquidityPool storage pool = liquidityPools[tokenAddress];
        require(address(pool.token) != address(0), "SuperToken2: invalid token");
        require(pool.totalDeposits - pool.totalBorrowed >= amount, "SuperToken2: insufficient liquidity");

        uint256 collateral = (amount * COLLATERALIZATION_RATIO) / 100;
        pool.token.safeTransferFrom(msg.sender, address(this), collateral);

        pool.totalBorrowed += amount;

        loans[msg.sender] = Loan({
            amount: amount,
            collateral: collateral,
            borrowBlock: block.number,
            loanType: loanType,
            tokenAddress: tokenAddress
        });

        pool.token.safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, tokenAddress, amount, collateral);
    }


    // ========================== Repay Function ==========================

    /**
     * @dev Allows borrowers to repay their loans and reclaim their collateral.
     */
    /**unction repay() external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.amount > 0, "SuperToken2: no active loan");

        LiquidityPool storage pool = liquidityPools[loan.tokenAddress];
        require(address(pool.token) != address(0), "SuperToken2: invalid token");

        uint256 fee = calculateFee(loan.amount, loan.loanType);

        // Borrower repays the loan amount plus fee
        uint256 repaymentAmount = loan.amount + fee;
        pool.token.safeTransferFrom(msg.sender, address(this), repaymentAmount);

        pool.totalBorrowed -= loan.amount;
        pool.totalFees += fee;

        // Distribute the collected fee
        pool.distributeFees(fee);

        // Return collateral
        pool.token.safeTransfer(msg.sender, loan.collateral);

        delete loans[msg.sender];

        emit Repaid(msg.sender, loan.tokenAddress, loan.amount, loan.collateral, fee);
    }**/

    function repay() external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.amount > 0, "No active loan");

        LiquidityPool storage pool = liquidityPools[loan.tokenAddress];
        require(address(pool.token) != address(0), "Invalid token");

        uint256 fee = calculateFee(loan.amount, loan.loanType);
        uint256 totalDue = loan.amount + fee;
        require(loan.collateral >= totalDue, "Insufficient collateral to cover loan and fee");

        // Deduct loan amount and fee from collateral
        uint256 netCollateralReturn = loan.collateral - totalDue;

        // Update state variables
        pool.totalBorrowed -= loan.amount;
        pool.totalFees += fee;
        pool.distributeFees(fee);

       
        // Return net collateral to borrower
        if (netCollateralReturn > 0) {
            pool.token.safeTransfer(msg.sender, netCollateralReturn);
        }

        // Delete loan record
        delete loans[msg.sender];

        emit Repaid(msg.sender, loan.tokenAddress, loan.amount, netCollateralReturn, fee);
    }



    // ========================== Force Repayment Function ==========================

    /**
     * @dev Allows admins to force repay a user's loan after the loan duration has expired.
     *      The fee is split between admin and holders.
     * @param borrower The address of the borrower whose loan is to be forcefully repaid.
     */
    function forceRepayment(address borrower) external onlyRole(ADMIN_ROLE) nonReentrant {
        Loan storage loan = loans[borrower];
        require(loan.amount > 0, "SuperToken2: no active loan");

        LiquidityPool storage pool = liquidityPools[loan.tokenAddress];
        require(address(pool.token) != address(0), "SuperToken2: invalid token");

        LoanType loanType = loan.loanType;
        LoanTerms memory terms = loanTerms[loanType];

        require(block.number >= loan.borrowBlock + terms.durationInBlocks, "SuperToken2: loan not expired");

        uint256 fee = calculateFee(loan.amount, loanType);
        require(fee <= loan.collateral, "SuperToken2: fee exceeds collateral");

        pool.totalBorrowed -= loan.amount;
        pool.totalFees += fee;

        // Distribute the collected fee
        pool.distributeFees(fee);

        uint256 collateralReturn = loan.collateral - fee;
        pool.token.safeTransfer(borrower, collateralReturn);

        delete loans[borrower];

        emit ForcedRepayment(borrower, loan.tokenAddress, loan.amount, collateralReturn);
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
        require(amount > 0, "SuperToken2: zero flash loan amount");
        LiquidityPool storage pool = liquidityPools[tokenAddress];
        require(address(pool.token) != address(0), "SuperToken2: invalid token");
        require(pool.totalDeposits - pool.totalBorrowed >= amount, "SuperToken2: insufficient liquidity");

        uint256 fee = (amount * FLASHLOAN_FEE_BPS) / BASIS_POINTS_DIVISOR;
        uint256 repaymentAmount = amount + fee;

        uint256 balanceBefore = pool.token.balanceOf(address(this));

        pool.token.safeTransfer(receiver, amount);

        IFlashLoanReceiver2(receiver).executeOperation(tokenAddress, amount, fee, msg.sender, params);

        uint256 balanceAfter = pool.token.balanceOf(address(this));
        require(balanceAfter >= balanceBefore + fee, "SuperToken2: flash loan not repaid");

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
    function withdrawAdminFees(address tokenAddress) external onlyRole(ADMIN_ROLE) nonReentrant {
        LiquidityPool storage pool = liquidityPools[tokenAddress];
        require(address(pool.token) != address(0), "SuperToken2: invalid token");
        require(pool.adminFees > 0, "SuperToken2: no admin fees");

        uint256 amt = pool.adminFees;
        pool.adminFees = 0;
        pool.token.safeTransfer(msg.sender, amt);

        emit AdminFeesWithdrawn(msg.sender, tokenAddress, amt);
    }

    /**
     * @dev Allows admins to set new loan parameters.
     * @param loanType The type of loan to set parameters for.
     * @param durationInBlocks The duration of the loan in blocks.
     * @param apyBps The APY of the loan in basis points.
     */
    function setLoanParameters(
        LoanType loanType,
        uint256 durationInBlocks,
        uint256 apyBps
    ) external onlyRole(ADMIN_ROLE) {
        loanTerms[loanType] = LoanTerms(durationInBlocks, apyBps);
    }

    /**
     * @dev Allows admins to set a new flash loan fee in basis points.
     * @param newFeeBps The new flash loan fee in basis points.
     */
    function setFlashLoanFeeBPS(uint256 newFeeBps) external onlyRole(ADMIN_ROLE) {
        require(newFeeBps <= BASIS_POINTS_DIVISOR, "SuperToken2: invalid fee");
        FLASHLOAN_FEE_BPS = newFeeBps;
        // Optionally emit an event
    }

    // ========================== View Functions ==========================

    /**
     * @dev Returns the loan details of a borrower.
     * @param borrower The address of the borrower.
     */
    function getLoanDetails(address borrower) external view returns (Loan memory) {
        return loans[borrower];
    }

    /**
     * @dev Returns the total available liquidity across all underlying tokens.
     */
    function totalAvailableLiquidity() external view returns (uint256 total) {
        for (uint256 i = 0; i < underlyingTokens.length; i++) {
            LiquidityPool storage pool = liquidityPools[address(underlyingTokens[i])];
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
    function getUnderlyingTokens() public view returns (address[] memory tokens) {
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
     * @dev Internal function to calculate fees using the FeeCalculator library.
     * @param amount The amount involved in the transaction.
     * @param loanType The type of loan.
     * @return fee The calculated fee.
     */
    function calculateFee(uint256 amount, LoanType loanType) internal view returns (uint256 fee) {
        LoanTerms memory terms = loanTerms[loanType];
        fee = FeeCalculator.calculateFee(amount, terms, BLOCKS_IN_A_YEAR, MINIMUM_FEE_BPS);
    }

    // ========================== Fallback and Receive ==========================

    fallback() external payable {
        revert("SuperToken2: cannot accept ETH");
    }

    receive() external payable {
        revert("SuperToken2: cannot accept ETH");
    }
}
