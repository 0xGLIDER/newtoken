

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDC
 * @dev A mock implementation of the USD Coin (USDC) token for testing purposes.
 *      Includes functionality for setting a fixed decimal, as well as minting and burning tokens.
 *      The contract owner has exclusive rights to mint new tokens.
 */
contract MockUSDC is ERC20, Ownable {

    // ========================== State Variables ==========================

    uint8 private immutable _decimals; // Fixed decimal places for the token

    // ========================== Constructor ==========================

    /**
     * @dev Sets the initial token supply, token decimals, and assigns ownership to the deployer.
     * @param initialSupply The initial supply of tokens to mint.
     * @param decimals_ The number of decimal places for the token (typically 6 for USDC).
     */
    constructor(uint256 initialSupply, uint8 decimals_) ERC20("Mock USD Coin", "mUSDC") Ownable(_msgSender()) {
        _decimals = decimals_; // Set custom decimal places
        _mint(msg.sender, initialSupply); // Mint initial supply to deployer
    }

    // ========================== Public Functions ==========================

    /**
     * @dev Overrides the decimals function to set a fixed number of decimals for the token.
     * @return The number of decimal places for the token.
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    // ========================== Mint Function ==========================

    /**
     * @dev Mints new tokens to a specified address. Only callable by the contract owner.
     * @param to The address to receive the newly minted tokens.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    // ========================== Burn Function ==========================

    /**
     * @dev Burns a specified amount of tokens from the caller's address.
     * @param amount The amount of tokens to burn.
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
