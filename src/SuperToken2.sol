// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin Contracts
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol"; // Updated Import
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/ITokenSwap.sol";
import "./interfaces/ITokenIface.sol";
import "./interfaces/IFlashLoanReceiver.sol";


/**
 * @title SuperToken
 * @dev A token representing a basket of underlying tokens with integrated lending and flash loan functionality.
 */
contract SuperToken is ERC20, ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20Metadata;

    // ========================== State Variables ==========================

    IERC20Metadata[] public underlyingTokens;      // Updated to IERC20Metadata
    uint256[] public amountsPerSuperToken;         // Amounts of each underlying token required per SuperToken

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint8 private constant _decimals = 18;

    // Lending Parameters
    uint256 public COLLATERALIZATION_RATIO = 150; // 150% collateralization

    // Fees and Durations
    uint256 public LOAN_DURATION_IN_BLOCKS = 241920;     // Approx. 14 days
    uint256 public LOAN_DURATION_IN_BLOCKS_1 = 1555200;  // Approx. 3 months
    uint256 public LOAN_DURATION_IN_BLOCKS_2 = 3110400;  // Approx. 6 months
    uint256 public LOAN_DURATION_IN_BLOCKS_3 = 6307200;  // Approx. 1 year

    uint256 public APY_BPS = 550;    // 5.5% APY in basis points
    uint256 public APY_BPS_1 = 650;  // 6.5% APY in basis points
    uint256 public APY_BPS_2 = 700;  // 7% APY in basis points
    uint256 public APY_BPS_3 = 900;  // 9% APY in basis points

    uint256 public BASIS_POINTS_DIVISOR = 10000;
    uint256 public BLOCKS_IN_A_YEAR = 6307200; // Total blocks in a year at 5-second block time
    uint256 public MINIMUM_FEE_BPS = 10;       // Minimum fee of 0.10% in basis points
    uint256 public FLASHLOAN_FEE_BPS = 5;      // Flash loan fee of 0.05% in basis points

    // Pool Metrics
    uint256 public totalDeposits;        // Total underlying assets deposited
    uint256 public totalLoans;           // Total active loans
    uint256 public totalAdminFees;       // Total fees accumulated for admin
    uint256 public totalHolderFees;      // Total fees accrued for SuperToken holders

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
    TokenIface public token;              // Interface for burnFrom functionality
    ITokenSwap public tokenSwap;          // External TokenSwap contract

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

    // ========================== Constructor ==========================

    /**
     * @dev Constructor for SuperToken.
     * @param name Name of the Super Token.
     * @param symbol Symbol of the Super Token.
     * @param _underlyingTokens Array of underlying ERC20 token addresses.
     * @param _amountsPerSuperToken Array of amounts required per Super Token for each underlying token.
     * @param _token Address of the TokenIface contract with burnFrom functionality.
     * @param _tokenSwap Address of the TokenSwap contract.
     */
    constructor(
        string memory name,
        string memory symbol,
        IERC20Metadata[] memory _underlyingTokens,
        uint256[] memory _amountsPerSuperToken,
        TokenIface _token,
        ITokenSwap _tokenSwap
    ) ERC20(name, symbol) {
        require(
            _underlyingTokens.length >= 2 && _underlyingTokens.length <= 10,
            "Must have between 2 and 10 underlying tokens"
        );
        require(
            _underlyingTokens.length == _amountsPerSuperToken.length,
            "Tokens and amounts length mismatch"
        );

        underlyingTokens = _underlyingTokens;
        amountsPerSuperToken = _amountsPerSuperToken;

        token = _token;
        tokenSwap = _tokenSwap;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ========================== ERC20 Overrides ==========================

    /**
     * @dev Returns the number of decimals used to get its user representation.
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    // ========================== Deposit Function ==========================

    /**
     * @dev Allows users to deposit underlying tokens and mint Super Tokens.
     * @param superAmount The amount of Super Tokens to mint (in 18 decimals).
     */
    function deposit(uint256 superAmount) external nonReentrant {
        require(superAmount > 0, "Amount must be greater than zero");

        uint256 len = underlyingTokens.length;
        for (uint256 i = 0; i < len; i++) {
            IERC20Metadata tokenContractInstance = underlyingTokens[i];
            uint8 tokenDecimals = tokenContractInstance.decimals();

            // Calculate the required amount in the smallest unit of the token
            uint256 totalAmount = (superAmount * amountsPerSuperToken[i]) / (10 ** _decimals);

            // Adjust for token decimals if different from 18
            if (tokenDecimals < _decimals) {
                totalAmount = totalAmount / (10 ** (_decimals - tokenDecimals));
            } else if (tokenDecimals > _decimals) {
                totalAmount = totalAmount * (10 ** (tokenDecimals - _decimals));
            }
            // If tokenDecimals == _decimals, no adjustment needed

            uint256 balanceBefore = tokenContractInstance.balanceOf(address(this));
            tokenContractInstance.safeTransferFrom(msg.sender, address(this), totalAmount);
            uint256 balanceAfter = tokenContractInstance.balanceOf(address(this));
            require(
                balanceAfter - balanceBefore == totalAmount,
                "Incorrect token amount received"
            );
        }

        _mint(msg.sender, superAmount);
        totalDeposits += superAmount;

        emit Deposit(msg.sender, superAmount);
    }

    // ========================== Redeem Function ==========================

    /**
     * @dev Allows users to burn Super Tokens and redeem underlying tokens, including their share of fees.
     * @param superAmount The amount of Super Tokens to redeem.
     */
    function redeem(uint256 superAmount) external nonReentrant {
        require(superAmount > 0, "Amount must be greater than zero");
        require(balanceOf(msg.sender) >= superAmount, "Insufficient Super Tokens");

        // Calculate user's share of total deposits and fees
        uint256 totalSupply_ = totalSupply();
        uint256 userShare = (superAmount * 1e18) / totalSupply_; // Scaled by 1e18 for precision

        // Burn the user's SuperTokens
        _burn(msg.sender, superAmount);

        uint256 len = underlyingTokens.length;
        for (uint256 i = 0; i < len; i++) {
            IERC20Metadata tokenContractInstance = underlyingTokens[i];
            uint8 tokenDecimals = tokenContractInstance.decimals();

            // Calculate user's share of the underlying tokens and accumulated fees
            uint256 totalTokenBalance = tokenContractInstance.balanceOf(address(this));
            uint256 userAmount = (totalTokenBalance * userShare) / 1e18;

            // Adjust for token decimals if different from 18
            if (tokenDecimals < _decimals) {
                userAmount = userAmount / (10 ** (_decimals - tokenDecimals));
            } else if (tokenDecimals > _decimals) {
                userAmount = userAmount * (10 ** (tokenDecimals - _decimals));
            }
            // If tokenDecimals == _decimals, no adjustment needed

            tokenContractInstance.safeTransfer(msg.sender, userAmount);
        }

        // Adjust total deposits and holder fees
        totalDeposits -= superAmount;
        totalHolderFees -= (totalHolderFees * userShare) / 1e18;

        emit Redeem(msg.sender, superAmount);
    }

    // ========================== Borrow Function ==========================

    /**
     * @dev Allows users to borrow underlying tokens by providing collateral.
     * @param amount The amount of underlying tokens to borrow (in SuperToken units).
     * @param loanLength Duration identifier for the loan.
     */
    function borrow(uint256 amount, uint256 loanLength) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(loans[msg.sender].amount == 0, "Existing loan active");
        require(
            loanLength == 1 || loanLength == 2 || loanLength == 3 || loanLength == 4,
            "Invalid loan duration"
        );

        uint256 collateralAmount = (amount * COLLATERALIZATION_RATIO) / 100;

        // Transfer collateral (in SuperToken) from borrower to contract
        _transfer(msg.sender, address(this), collateralAmount);

        // Ensure sufficient liquidity in underlying tokens
        require(
            totalAvailableLiquidity() >= amount,
            "Insufficient liquidity"
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
            IERC20Metadata tokenContractInstance = underlyingTokens[i];
            uint8 tokenDecimals = tokenContractInstance.decimals();

            uint256 tokenAmount = (amount * amountsPerSuperToken[i]) / (10 ** _decimals);

            // Adjust for token decimals if different from 18
            if (tokenDecimals < _decimals) {
                tokenAmount = tokenAmount / (10 ** (_decimals - tokenDecimals));
            } else if (tokenDecimals > _decimals) {
                tokenAmount = tokenAmount * (10 ** (tokenDecimals - _decimals));
            }
            // If tokenDecimals == _decimals, no adjustment needed

            tokenContractInstance.safeTransfer(msg.sender, tokenAmount);
        }

        emit Borrowed(msg.sender, amount, collateralAmount);
    }

    // ========================== Repay Function ==========================

    /**
     * @dev Allows borrowers to repay their loans and retrieve their collateral.
     */
    function repay() external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.amount > 0, "No active loan");

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
            revert("Invalid loan duration");
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
            IERC20Metadata tokenContractInstance = underlyingTokens[i];
            uint8 tokenDecimals = tokenContractInstance.decimals();

            uint256 tokenAmount = (amountToRepay * amountsPerSuperToken[i]) / (10 ** _decimals);

            // Adjust for token decimals if different from 18
            if (tokenDecimals < _decimals) {
                tokenAmount = tokenAmount / (10 ** (_decimals - tokenDecimals));
            } else if (tokenDecimals > _decimals) {
                tokenAmount = tokenAmount * (10 ** (tokenDecimals - _decimals));
            }
            // If tokenDecimals == _decimals, no adjustment needed

            tokenContractInstance.safeTransferFrom(msg.sender, address(this), tokenAmount);
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
        require(loan.amount > 0, "No active loan");

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
            revert("Invalid loan duration");
        }

        require(
            block.number >= loan.borrowBlock + applicableLoanDuration,
            "Loan duration not expired"
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
        totalDeposits += loan.collateral - fee;

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
        require(amount > 0, "Amount must be greater than zero");
        require(amount <= totalAvailableLiquidity(), "Not enough liquidity for flashloan");

        // Calculate the fee and total repayment amount
        uint256 fee = (amount * FLASHLOAN_FEE_BPS) / BASIS_POINTS_DIVISOR;
        uint256 repaymentAmount = amount + fee;

        // Record the initial available liquidity
        uint256 balanceBefore = totalAvailableLiquidity();

        // Transfer the borrowed amount to the receiver
        _transfer(address(this), receiverAddress, amount);

        // The receiver executes their custom logic
        IFlashLoanReceiver(receiverAddress).executeOperation(amount, fee, params);

        // After the operation, ensure that the loan plus fee has been repaid
        uint256 balanceAfter = totalAvailableLiquidity();
        require(
            balanceAfter >= balanceBefore + fee,
            "Flashloan not repaid with fee"
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
        require(totalAdminFees > 0, "No admin fees to withdraw");

        uint256 len = underlyingTokens.length;
        for (uint256 i = 0; i < len; i++) {
            IERC20Metadata tokenContractInstance = underlyingTokens[i];
            uint8 tokenDecimals = tokenContractInstance.decimals();

            // Calculate admin fee amount for each token
            uint256 tokenFeeAmount = (totalAdminFees * amountsPerSuperToken[i]) / (10 ** _decimals);

            // Adjust for token decimals if different from 18
            if (tokenDecimals < _decimals) {
                tokenFeeAmount = tokenFeeAmount / (10 ** (_decimals - tokenDecimals));
            } else if (tokenDecimals > _decimals) {
                tokenFeeAmount = tokenFeeAmount * (10 ** (tokenDecimals - _decimals));
            }
            // If tokenDecimals == _decimals, no adjustment needed

            tokenContractInstance.safeTransfer(msg.sender, tokenFeeAmount);
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
            IERC20Metadata tokenContractInstance = underlyingTokens[i];
            uint8 tokenDecimals = tokenContractInstance.decimals();

            uint256 balance = tokenContractInstance.balanceOf(address(this));

            // Convert the balance to SuperToken units
            uint256 tokenAmountInSuperTokenUnits = (balance * (10 ** _decimals)) / amountsPerSuperToken[i];

            // Adjust for token decimals if different from 18
            if (tokenDecimals < _decimals) {
                tokenAmountInSuperTokenUnits = tokenAmountInSuperTokenUnits / (10 ** (_decimals - tokenDecimals));
            } else if (tokenDecimals > _decimals) {
                tokenAmountInSuperTokenUnits = tokenAmountInSuperTokenUnits * (10 ** (tokenDecimals - _decimals));
            }
            // If tokenDecimals == _decimals, no adjustment needed

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

    receive() external payable {
        revert("Cannot receive Ether");
    }

    fallback() external payable {
        revert("Fallback not allowed");
    }
}
