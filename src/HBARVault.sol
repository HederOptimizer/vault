//SPDX-License-Identitifier: MIT
pragma solidity 0.8.29;

import {ERC4626Native} from "./ERC4626/ERC4626Native.sol";

/**
 * @title IStrategy
 * @notice Interface for a simple ETH staking strategy.
 * Strategies are managed by the LiquidStakingVault.
 */
interface IStrategy {
    /**
     * @notice Deposit ETH into the strategy.
     * @dev MUST be payable.
     * @dev MUST revert if caller is not the vault.
     */
    function deposit() external payable;

    /**
     * @notice Withdraw ETH from the strategy.
     * @param amount The amount of ETH to withdraw.
     * @dev MUST revert if caller is not the vault.
     * @dev MUST send the ETH to the vault.
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Reports the total ETH balance of the strategy.
     * @dev This should include any rewards earned.
     * @return balance The total ETH held by the strategy.
     */
    function balance() external view returns (uint256);
}


/*//////////////////////////////////////////////////////////////
//
// 3. LIQUID STAKING VAULT IMPLEMENTATION
//
//////////////////////////////////////////////////////////////*/

/**
 * @title LiquidStakingVault
 * @notice An ERC4626 vault for liquid-staking native ETH into various strategies.
 * @dev Inherits from ERC4626Native and implements its abstract `totalAssets` function.
 */
contract LiquidStakingVault is ERC4626Native {
    
    // --- State Variables ---

    /// @notice The admin of the vault, allowed to manage strategies.
    address public immutable owner;

    /// @notice The list of all approved strategies.
    IStrategy[] public strategies;

    /// @notice Mapping to quickly check if a strategy is registered.
    mapping(address => bool) public isStrategy;

    /// @notice The default strategy to which new deposits are sent.
    IStrategy public activeStrategy;

    // --- Events ---

    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event ActiveStrategyUpdated(address indexed strategy);
    event Rebalanced(address indexed caller);

    // --- Modifiers ---

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    // --- Constructor ---

    constructor(
        string memory _name,
        string memory _symbol
    ) ERC4626Native(_name, _symbol) {
        owner = msg.sender;
    }

    // --- ERC4626 Implementation ---

    /**
     * @notice Calculates the total ETH managed by the vault.
     * @dev This is the sum of ETH held idle in this contract AND
     * all ETH held in the registered strategies (including rewards).
     * This is the core implementation required by ERC4626Native.
     */
    function totalAssets() public view override returns (uint256) {
        uint256 totalInvested = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            totalInvested += strategies[i].balance();
        }
        return address(this).balance + totalInvested;
    }

    // --- Internal Hooks Implementation ---

    /**
     * @notice Hook called after a deposit.
     * @dev Deposits the received assets into the active strategy.
     * If no active strategy is set, the ETH remains in the vault.
     */
    function afterDeposit(uint256 assets, uint256 shares) internal override {
        // If there's an active strategy, deposit the new ETH into it
        if (address(activeStrategy) != address(0)) {
            activeStrategy.deposit{value: assets}();
        }
        // If no active strategy, ETH just sits in this contract,
        // which is correctly accounted for by totalAssets().
    }

    /**
     * @notice Hook called before a withdrawal.
     * @dev Ensures the vault has enough liquid ETH to cover the withdrawal.
     * It pulls ETH from its own balance first, then from strategies if needed.
     */
    function beforeWithdraw(uint256 assets, uint256 shares) internal override {
        uint256 ethInContract = address(this).balance;

        if (ethInContract < assets) {
            uint256 needed = assets - ethInContract;

            // Need to pull funds from strategies.
            // We'll iterate in reverse (LIFO) for simplicity.
            // A more complex vault might have sophisticated withdrawal logic.
            for (uint256 i = strategies.length; i > 0; i--) {
                uint256 strategyIndex = i - 1;
                IStrategy strategy = strategies[strategyIndex];
                uint256 strategyBal = strategy.balance();

                if (strategyBal == 0) continue;

                if (needed <= strategyBal) {
                    // This strategy has enough
                    strategy.withdraw(needed);
                    needed = 0;
                    break; // We're done
                } else {
                    // This strategy doesn't have enough, drain it and continue
                    strategy.withdraw(strategyBal);
                    needed -= strategyBal;
                }
            }
            require(needed == 0, "INSUFFICIENT_LIQUIDITY");
        }
    }

    // --- Strategy Management (Owner Only) ---

    /**
     * @notice Adds a new staking strategy to the vault.
     * @param _strategy The address of the strategy contract.
     */
    function addStrategy(IStrategy _strategy) external onlyOwner {
        address strategyAddr = address(_strategy);
        require(strategyAddr != address(0), "ZERO_ADDRESS");
        require(!isStrategy[strategyAddr], "ALREADY_REGISTERED");
        
        strategies.push(_strategy);
        isStrategy[strategyAddr] = true;
        emit StrategyAdded(strategyAddr);
    }

    /**
     * @notice Removes a staking strategy from the vault.
     * @dev This will first withdraw all funds from the strategy.
     * @param _strategy The strategy contract to remove.
     */
    function removeStrategy(IStrategy _strategy) external onlyOwner {
        address strategyAddr = address(_strategy);
        require(isStrategy[strategyAddr], "NOT_REGISTERED");

        // 1. Pull all funds from the strategy
        uint256 bal = _strategy.balance();
        if (bal > 0) {
            _strategy.withdraw(bal);
        }

        // 2. Deactivate if it's the active strategy
        if (activeStrategy == _strategy) {
            activeStrategy = IStrategy(address(0));
            emit ActiveStrategyUpdated(address(0));
        }

        // 3. Remove from array (swap with last element and pop)
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i] == _strategy) {
                strategies[i] = strategies[strategies.length - 1];
                strategies.pop();
                break;
            }
        }
        
        isStrategy[strategyAddr] = false;
        emit StrategyRemoved(strategyAddr);
    }

    /**
     * @notice Sets the active strategy for new deposits.
     * @param _strategy The strategy to set as active. Must already be registered.
     */
    function updateActiveStrategy(IStrategy _strategy) external onlyOwner {
        address strategyAddr = address(_strategy);
        // Allow setting to address(0) to halt new deposits
        if (strategyAddr != address(0)) {
            require(isStrategy[strategyAddr], "NOT_REGISTERED");
        }
        activeStrategy = _strategy;
        emit ActiveStrategyUpdated(strategyAddr);
    }

    /**
     * @notice Rebalances all vault assets according to specified targets.
     * @dev This function first withdraws ALL funds from ALL strategies,
     * then redeploys the ETH to the target strategies.
     * @param _targetStrategies Array of strategies to deploy funds to.
     * @param _targetAmounts Array of ETH amounts to deploy to each strategy.
     * @dev Any ETH not allocated will be held idle in the vault.
     * @dev This is a simple but potentially gas-intensive implementation.
     */
    function rebalance(
        IStrategy[] calldata _targetStrategies, 
        uint256[] calldata _targetAmounts
    ) external onlyOwner {
        require(_targetStrategies.length == _targetAmounts.length, "ARRAY_LENGTH_MISMATCH");

        // 1. Pull all funds back to the vault
        for (uint256 i = 0; i < strategies.length; i++) {
            IStrategy strategy = strategies[i];
            uint256 bal = strategy.balance();
            if (bal > 0) {
                strategy.withdraw(bal);
            }
        }

        // 2. Now, address(this).balance holds totalAssets()
        uint256 totalBalance = address(this).balance;
        uint256 totalAllocated = 0;

        // 3. Deploy funds to new targets
        for (uint256 i = 0; i < _targetStrategies.length; i++) {
            uint256 amount = _targetAmounts[i];
            if (amount == 0) continue;

            // Ensure this is a known strategy
            require(isStrategy[address(_targetStrategies[i])], "TARGET_NOT_REGISTERED");
            
            // Ensure we have the funds
            uint256 newTotalAllocated = totalAllocated + amount;
            require(totalBalance >= newTotalAllocated, "INSUFFICIENT_FUNDS_FOR_REBALANCE");
            
            totalAllocated = newTotalAllocated;
            
            // Deploy funds
            _targetStrategies[i].deposit{value: amount}();
        }
        
        // Any remaining funds (totalBalance - totalAllocated) stay in the vault.
        emit Rebalanced(msg.sender);
    }

    // --- Receive ---

    /**
     * @notice We must be able to receive ETH from strategy withdrawals.
     * @dev The base contract's receive() is external, so this is fine,
     * but we add an explicit receive() to be clear and to allow
     * strategies (or anyone) to send ETH back.
     * Strategies should be whitelist-based, but this provides a fallback.
     */
    receive() external payable override {}
}