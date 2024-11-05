// contracts/SuperToken2.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin Upgradeable Contracts
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import Interfaces
import "./interfaces/ITokenSwap.sol";
import "./interfaces/IEqualFiToken.sol";
import "./interfaces/IFlashLoanReceiver1.sol";

/**
 * @title SuperToken2
 * @dev A token representing a basket of underlying tokens with integrated lending and flash loan functionality.
 */
contract SuperToken2 is Initializable, ERC20Upgradeable, ReentrancyGuardUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20Metadata;

    // Define roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Lending Parameters
    uint256 public COLLATERALIZATION_RATIO; // e.g., 150 for 150%

    // Fees and Durations
    uint256 public LOAN_DURATION_IN_BLOCKS;      // Approx. 14 days
    uint256 public LOAN_DURATION_IN_BLOCKS_1;    // Approx. 3 months
    uint256 public LOAN_DURATION_IN_BLOCKS_2;    // Approx. 6 months
    uint256 public LOAN_DURATION_IN_BLOCKS_3;    // Approx. 1 year

    uint256 public APY_BPS;     // 5.5% APY in basis points
    uint256 public APY_BPS_1;   // 6.5% APY in basis points
    uint256 public APY_BPS_2;   // 7% APY in basis points
    uint256 public APY_BPS_3;   // 9% APY in basis points

    uint256 public BASIS_POINTS_DIVISOR; // 10000
    uint256 public BLOCKS_IN_A_YEAR;     // Total blocks in a year at 5-second block time
    uint256 public MINIMUM_FEE_BPS;      // Minimum fee of 0.10% in basis points
    uint256 public FLASHLOAN_FEE_BPS;    // Flash loan fee of 0.05% in basis points

    // Pool Metrics
    uint256 public totalLoans;           // Total active loans
    uint256 public totalAdminFees;       // Total fees accumulated for admin
    uint256 public totalHolderFees;      // Total fees accrued for SuperToken holders

    IERC20Metadata[] public underlyingTokens;
    uint256[] public amountsPerSuperToken;


    // Loan Struct
    struct Loan {
        uint256 amount;        // Amount borrowed
        uint256 collateral;    // Collateral deposited
        uint256 borrowBlock;   // Block number when loan was taken
        uint256 loanDuration;  // Duration of loan
    }

    // Mappings
    mapping(address => Loan) public loans; // Tracks loans per user

    // Token Interfaces
    IEqualFiToken public token;        // Interface for burnFrom functionality
    //ITokenSwap public tokenSwap;     // External TokenSwap contract

    // Events
    event Deposit(address indexed user, uint256 superAmount);
    event Redeem(address indexed user, uint256 superAmount);
    event Borrowed(address indexed user, uint256 amount, uint256 collateral);
    event Repaid(address indexed user, uint256 amount, uint256 collateralReturned, uint256 feePaid);
    event ForcedRepayment(address indexed user, uint256 amount, uint256 collateralUsed);
    event AdminFeesWithdrawn(address indexed admin, uint256 amount);
    event FlashLoan(address indexed receiver, uint256 amount, uint256 fee);
    event TokensSwapped(address indexed user, address indexed inputToken, uint256 inputAmount, uint256 usdcReceived);
    event FlashLoanFeesUpdated(uint256 newFeeBPS);

    // ========================== Initialization ==========================

    /**
     * @dev Initializes the SuperToken2 clone with the provided parameters.
     * @param name Name of the Super Token.
     * @param symbol Symbol of the Super Token.
     * @param _underlyingTokens Array of underlying ERC20Metadata token addresses.
     * @param _amountsPerSuperToken Array of amounts required per Super Token for each underlying token.
     * @param _token Address of the TokenIface contract with burnFrom functionality.
     * @param admin Address to be granted admin roles.
     */
    function initialize(
        string memory name,
        string memory symbol,
        IERC20Metadata[] memory _underlyingTokens,
        uint256[] memory _amountsPerSuperToken,
        IEqualFiToken _token,
        address admin
    ) public initializer {
        __ERC20_init(name, symbol);
        __ReentrancyGuard_init();
        __AccessControl_init();

        require(
            _underlyingTokens.length >= 2 && _underlyingTokens.length <= 10,
            "SuperToken2: invalid number of underlying tokens"
        );
        require(
            _underlyingTokens.length == _amountsPerSuperToken.length,
            "SuperToken2: tokens and amounts length mismatch"
        );

        underlyingTokens = _underlyingTokens;
        amountsPerSuperToken = _amountsPerSuperToken;

        token = _token;

        // Set initial parameters
        COLLATERALIZATION_RATIO = 150; // Example value
        LOAN_DURATION_IN_BLOCKS = 241920;      // Approx. 14 days
        LOAN_DURATION_IN_BLOCKS_1 = 1555200;    // Approx. 3 months
        LOAN_DURATION_IN_BLOCKS_2 = 3110400;    // Approx. 6 months
        LOAN_DURATION_IN_BLOCKS_3 = 6307200;    // Approx. 1 year

        APY_BPS = 550;     // 5.5% APY
        APY_BPS_1 = 650;   // 6.5% APY
        APY_BPS_2 = 700;   // 7% APY
        APY_BPS_3 = 900;   // 9% APY

        BASIS_POINTS_DIVISOR = 10000;
        BLOCKS_IN_A_YEAR = 6307200; // Total blocks in a year at 5-second block time
        MINIMUM_FEE_BPS = 10;       // Minimum fee of 0.10%
        FLASHLOAN_FEE_BPS = 5;      // Flash loan fee of 0.05%

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    // ========================== ERC20 Overrides ==========================

    /**
     * @dev Returns the number of decimals used to get its user representation.
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    // ========================== Deposit Function ==========================

    /**
     * @dev Allows users to deposit underlying tokens and mint Super Tokens.
     * @param superAmount The amount of Super Tokens to mint (in 18 decimals).
     */
    function deposit(uint256 superAmount) external nonReentrant {
        require(superAmount > 0, "SuperToken2: amount must be greater than zero");

        uint256 len = underlyingTokens.length;
        for (uint256 i = 0; i < len; i++) {
            IERC20Metadata tokenContract = underlyingTokens[i];
            uint8 tokenDecimals = tokenContract.decimals();

            // Calculate the required amount in the smallest unit of the token
            uint256 requiredAmount = (superAmount * amountsPerSuperToken[i]) / (10 ** decimals());

            // Adjust for token decimals if different from 18
            if (tokenDecimals < decimals()) {
                requiredAmount = requiredAmount / (10 ** (decimals() - tokenDecimals));
            } else if (tokenDecimals > decimals()) {
                requiredAmount = requiredAmount * (10 ** (tokenDecimals - decimals()));
            }
            // If tokenDecimals == decimals(), no adjustment needed

            uint256 balanceBefore = tokenContract.balanceOf(address(this));
            tokenContract.safeTransferFrom(msg.sender, address(this), requiredAmount);
            uint256 balanceAfter = tokenContract.balanceOf(address(this));
            require(
                balanceAfter - balanceBefore == requiredAmount,
                "SuperToken2: incorrect token amount received"
            );
        }

        _mint(msg.sender, superAmount);

        emit Deposit(msg.sender, superAmount);
    }

    // ========================== Redeem Function ==========================

    /**
     * @dev Allows users to burn Super Tokens and redeem underlying tokens, including their share of fees.
     * @param superAmount The amount of Super Tokens to redeem.
     */
    function redeem(uint256 superAmount) external nonReentrant {
        require(superAmount > 0, "SuperToken2: amount must be greater than zero");
        require(balanceOf(msg.sender) >= superAmount, "SuperToken2: insufficient balance");

        // Calculate user's share of total supply
        uint256 totalSupply_ = totalSupply();
        uint256 userShare = (superAmount * 1e18) / totalSupply_; // Scaled by 1e18 for precision

        // Burn the user's SuperTokens
        _burn(msg.sender, superAmount);

        uint256 len = underlyingTokens.length;
        for (uint256 i = 0; i < len; i++) {
            IERC20Metadata tokenContract = underlyingTokens[i];
            uint8 tokenDecimals = tokenContract.decimals();

            // Calculate user's share of the underlying tokens
            uint256 totalTokenBalance = tokenContract.balanceOf(address(this));
            uint256 userAmount = (totalTokenBalance * userShare) / 1e18;

            // Adjust for token decimals if different from 18
            if (tokenDecimals < decimals()) {
                userAmount = userAmount / (10 ** (decimals() - tokenDecimals));
            } else if (tokenDecimals > decimals()) {
                userAmount = userAmount * (10 ** (tokenDecimals - decimals()));
            }
            // If tokenDecimals == decimals(), no adjustment needed

            tokenContract.safeTransfer(msg.sender, userAmount);
        }

        // Adjust holder fees
        if (totalHolderFees >= (totalHolderFees * userShare) / 1e18) {
            totalHolderFees -= (totalHolderFees * userShare) / 1e18;
        } else {
            totalHolderFees = 0;
        }

        emit Redeem(msg.sender, superAmount);
    }

    // ========================== Borrow Function ==========================

    /**
     * @dev Allows users to borrow underlying tokens by providing collateral.
     * @param amount The amount of underlying tokens to borrow (in SuperToken units).
     * @param loanLength Duration identifier for the loan.
     */
    function borrow(uint256 amount, uint256 loanLength) external nonReentrant {
        require(amount > 0, "SuperToken2: amount must be greater than zero");
        require(loans[msg.sender].amount == 0, "SuperToken2: existing loan active");
        require(
            loanLength >= 1 && loanLength <= 4,
            "SuperToken2: invalid loan duration"
        );

        uint256 collateralAmount = (amount * COLLATERALIZATION_RATIO) / 100;

        // Transfer collateral (in SuperToken) from borrower to contract
        _transfer(msg.sender, address(this), collateralAmount);

        // Ensure sufficient liquidity in underlying tokens
        require(
            totalAvailableLiquidity() >= amount,
            "SuperToken2: insufficient liquidity"
        );

        // Record the loan details
        loans[msg.sender] = Loan({
            amount: amount,
            collateral: collateralAmount,
            borrowBlock: block.number,
            loanDuration: loanLength
        });

        // Update total loans
        totalLoans += amount;

        // Transfer underlying tokens to borrower proportionally
        uint256 len = underlyingTokens.length;
        for (uint256 i = 0; i < len; i++) {
            IERC20Metadata tokenContract = underlyingTokens[i];
            uint8 tokenDecimals = tokenContract.decimals();

            uint256 tokenAmount = (amount * amountsPerSuperToken[i]) / (10 ** decimals());

            // Adjust for token decimals if different from 18
            if (tokenDecimals < decimals()) {
                tokenAmount = tokenAmount / (10 ** (decimals() - tokenDecimals));
            } else if (tokenDecimals > decimals()) {
                tokenAmount = tokenAmount * (10 ** (tokenDecimals - decimals()));
            }
            // If tokenDecimals == decimals(), no adjustment needed

            tokenContract.safeTransfer(msg.sender, tokenAmount);
        }

        emit Borrowed(msg.sender, amount, collateralAmount);
    }

    // ========================== Repay Function ==========================

    /**
     * @dev Allows borrowers to repay their loans and retrieve their collateral.
     */
    function repay() external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.amount > 0, "SuperToken2: no active loan");

        uint256 amountToRepay = loan.amount;
        uint256 fee;
        uint256 applicableAPY;
        uint256 applicableLoanDuration;

        // Determine applicable APY and loan duration
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
            revert("SuperToken2: invalid loan duration");
        }

        // Calculate blocks elapsed
        uint256 blocksElapsed = block.number - loan.borrowBlock;
        if (blocksElapsed > applicableLoanDuration) {
            blocksElapsed = applicableLoanDuration;
        }

        // Calculate fee
        uint256 calculatedFee = (amountToRepay * applicableAPY * blocksElapsed) / (BASIS_POINTS_DIVISOR * BLOCKS_IN_A_YEAR);
        uint256 minimumFee = (amountToRepay * MINIMUM_FEE_BPS) / BASIS_POINTS_DIVISOR;
        fee = calculatedFee > minimumFee ? calculatedFee : minimumFee;

        // Split fee between admin and SuperToken holders
        uint256 adminFee = (fee * 5) / BASIS_POINTS_DIVISOR; // 0.05% to admin
        uint256 holderFee = fee - adminFee;

        totalAdminFees += adminFee;
        totalHolderFees += holderFee;

        // Transfer underlying tokens from borrower to contract
        uint256 len = underlyingTokens.length;
        for (uint256 i = 0; i < len; i++) {
            IERC20Metadata tokenContract = underlyingTokens[i];
            uint8 tokenDecimals = tokenContract.decimals();

            uint256 tokenAmount = (amountToRepay * amountsPerSuperToken[i]) / (10 ** decimals());

            // Adjust for token decimals if different from 18
            if (tokenDecimals < decimals()) {
                tokenAmount = tokenAmount / (10 ** (decimals() - tokenDecimals));
            } else if (tokenDecimals > decimals()) {
                tokenAmount = tokenAmount * (10 ** (tokenDecimals - decimals()));
            }
            // If tokenDecimals == decimals(), no adjustment needed

            tokenContract.safeTransferFrom(msg.sender, address(this), tokenAmount);
        }

        // Return collateral minus fee to borrower
        uint256 collateralToReturn = loan.collateral - fee;
        _transfer(address(this), msg.sender, collateralToReturn);

        // Update total loans
        totalLoans -= loan.amount;

        // Delete loan record
        delete loans[msg.sender];

        emit Repaid(msg.sender, amountToRepay, collateralToReturn, fee);
    }

    // ========================== Force Repayment Function ==========================

    /**
     * @dev Allows admin to force repayment of a loan after loan duration expires.
     * @param borrower Address of the borrower.
     */
    function forceRepayment(address borrower) external onlyRole(ADMIN_ROLE) nonReentrant {
        Loan storage loan = loans[borrower];
        require(loan.amount > 0, "SuperToken2: no active loan");

        uint256 amountToRepay = loan.amount;
        uint256 fee;
        uint256 applicableAPY;
        uint256 applicableLoanDuration;

        // Determine applicable APY and loan duration
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
            revert("SuperToken2: invalid loan duration");
        }

        require(
            block.number >= loan.borrowBlock + applicableLoanDuration,
            "SuperToken2: loan duration not expired"
        );

        // Calculate fee
        fee = (amountToRepay * applicableAPY * applicableLoanDuration) / (BASIS_POINTS_DIVISOR * BLOCKS_IN_A_YEAR);
        uint256 minimumFee = (amountToRepay * MINIMUM_FEE_BPS) / BASIS_POINTS_DIVISOR;
        if (fee < minimumFee) {
            fee = minimumFee;
        }

        // Split fee between admin and SuperToken holders
        uint256 adminFee = (fee * 5) / BASIS_POINTS_DIVISOR; // 0.05% to admin
        uint256 holderFee = fee - adminFee;

        totalAdminFees += adminFee;
        totalHolderFees += holderFee;

        // Update total loans
        totalLoans -= loan.amount;

        // Use collateral to cover loan repayment and fees
        // Any remaining collateral increases total deposits

        // Delete loan record
        delete loans[borrower];

        emit ForcedRepayment(borrower, amountToRepay, loan.collateral - fee);
    }

    // ========================== Flash Loan Function ==========================

    /**
     * @dev Allows users to perform a flash loan, which must be repaid within the same transaction.
     * @param receiverAddress The address of the contract implementing IFlashLoanReceiver.
     * @param amount The amount of SuperToken to borrow.
     * @param params Arbitrary data passed to the receiver's executeOperation function.
     */
    function flashLoan(
        address receiverAddress,
        uint256 amount,
        bytes calldata params
    ) external nonReentrant {
        require(amount > 0, "SuperToken2: amount must be greater than zero");
        require(amount <= totalAvailableLiquidity(), "SuperToken2: insufficient liquidity for flashloan");

        // Calculate the fee and total repayment amount
        uint256 fee = (amount * FLASHLOAN_FEE_BPS) / BASIS_POINTS_DIVISOR;
        uint256 repaymentAmount = amount + fee;

        // Record the initial available liquidity
        uint256 balanceBefore = totalAvailableLiquidity();

        // Transfer the borrowed amount to the receiver
        _transfer(address(this), receiverAddress, amount);

        // The receiver executes their custom logic
        IFlashLoanReceiver1(receiverAddress).executeOperation(amount, fee, params);

        // After the operation, ensure that the loan plus fee has been repaid
        uint256 balanceAfter = totalAvailableLiquidity();
        require(
            balanceAfter >= balanceBefore + fee,
            "SuperToken2: flashloan not repaid with fee"
        );

        // Split the fee between admin and SuperToken holders
        uint256 adminFee = (fee * 5) / BASIS_POINTS_DIVISOR; // 0.05% to admin
        uint256 holderFee = fee - adminFee;

        totalAdminFees += adminFee;
        totalHolderFees += holderFee;

        emit FlashLoan(receiverAddress, amount, fee);
    }

    // ========================== Admin Functions ==========================

    /**
     * @dev Allows admin to withdraw accumulated admin fees in underlying tokens.
     */
    function withdrawAdminFees() external onlyRole(ADMIN_ROLE) nonReentrant {
        require(totalAdminFees > 0, "SuperToken2: no admin fees to withdraw");

        uint256 len = underlyingTokens.length;
        for (uint256 i = 0; i < len; i++) {
            IERC20Metadata tokenContract = underlyingTokens[i];
            uint8 tokenDecimals = tokenContract.decimals();

            // Calculate admin fee amount for each token
            uint256 tokenFeeAmount = (totalAdminFees * amountsPerSuperToken[i]) / (10 ** decimals());

            // Adjust for token decimals if different from 18
            if (tokenDecimals < decimals()) {
                tokenFeeAmount = tokenFeeAmount / (10 ** (decimals() - tokenDecimals));
            } else if (tokenDecimals > decimals()) {
                tokenFeeAmount = tokenFeeAmount * (10 ** (tokenDecimals - decimals()));
            }
            // If tokenDecimals == decimals(), no adjustment needed

            tokenContract.safeTransfer(msg.sender, tokenFeeAmount);
        }

        emit AdminFeesWithdrawn(msg.sender, totalAdminFees);
        totalAdminFees = 0;
    }

    /**
     * @dev Allows admin to set new loan parameters.
     */
    function setLoanParameters(
        uint256 _COLLATERALIZATION_RATIO,
        uint256 _LOAN_DURATION_IN_BLOCKS,
        uint256 _LOAN_DURATION_IN_BLOCKS_1,
        uint256 _LOAN_DURATION_IN_BLOCKS_2,
        uint256 _LOAN_DURATION_IN_BLOCKS_3,
        uint256 _APY_BPS,
        uint256 _APY_BPS_1,
        uint256 _APY_BPS_2,
        uint256 _APY_BPS_3
    ) external onlyRole(ADMIN_ROLE) {
        COLLATERALIZATION_RATIO = _COLLATERALIZATION_RATIO;
        LOAN_DURATION_IN_BLOCKS = _LOAN_DURATION_IN_BLOCKS;
        LOAN_DURATION_IN_BLOCKS_1 = _LOAN_DURATION_IN_BLOCKS_1;
        LOAN_DURATION_IN_BLOCKS_2 = _LOAN_DURATION_IN_BLOCKS_2;
        LOAN_DURATION_IN_BLOCKS_3 = _LOAN_DURATION_IN_BLOCKS_3;
        APY_BPS = _APY_BPS;
        APY_BPS_1 = _APY_BPS_1;
        APY_BPS_2 = _APY_BPS_2;
        APY_BPS_3 = _APY_BPS_3;
    }

    /**
     * @dev Allows admin to set a new flash loan fee in basis points.
     * @param newFlashLoanFeeBPS The new flash loan fee in basis points.
     */
    function setFlashLoanFeeBPS(uint256 newFlashLoanFeeBPS) external onlyRole(ADMIN_ROLE) {
        FLASHLOAN_FEE_BPS = newFlashLoanFeeBPS;
        emit FlashLoanFeesUpdated(newFlashLoanFeeBPS);
    }

    // ========================== View Functions ==========================

    /**
     * @dev Returns the total available liquidity in underlying tokens.
     */
    function totalAvailableLiquidity() public view returns (uint256) {
        uint256 totalUnderlying = 0;
        uint256 len = underlyingTokens.length;
        for (uint256 i = 0; i < len; i++) {
            IERC20Metadata tokenContract = underlyingTokens[i];
            uint8 tokenDecimals = tokenContract.decimals();

            uint256 balance = tokenContract.balanceOf(address(this));

            // Convert the balance to SuperToken units
            uint256 tokenAmountInSuperTokenUnits = (balance * (10 ** decimals())) / amountsPerSuperToken[i];

            // Adjust for token decimals if different from 18
            if (tokenDecimals < decimals()) {
                tokenAmountInSuperTokenUnits = tokenAmountInSuperTokenUnits / (10 ** (decimals() - tokenDecimals));
            } else if (tokenDecimals > decimals()) {
                tokenAmountInSuperTokenUnits = tokenAmountInSuperTokenUnits * (10 ** (tokenDecimals - decimals()));
            }
            // If tokenDecimals == decimals(), no adjustment needed

            totalUnderlying += tokenAmountInSuperTokenUnits;
        }
        return totalUnderlying - totalLoans;
    }

    /**
     * @dev Returns the loan details of a borrower.
     * @param borrower The address of the borrower.
     */
    function getLoanDetails(address borrower) external view returns (Loan memory) {
        return loans[borrower];
    }

    // ========================== Fallback Functions ==========================

    fallback() external {
        revert("SuperToken2: fallback not allowed");
    }
}
