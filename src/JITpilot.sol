pragma solidity ^0.8.17;

/**
 * @title JITpilot Health Checker Keeper
 * @notice Automates partial debt repayment for JIT liquidity vaults based on dynamic LTV and net interest thresholds.
 */
contract JITpilotKeeper{
    // --- State variables ---

    /// @notice Trigger LTV (in basis points, e.g., 80% = 8000)
    uint256 public s_triggerLTV;
    /// @notice Target LTV to restore after repay (bps, e.g. 65% = 6500)
    uint256 public s_targetLTV;

    /// @notice ERC20 collateral token (e.g., USDC)
    IERC20 public s_collateral;
    /// @notice ERC20 debt token (e.g., WETH)
    IERC20 public s_debt;

    // --- Constructor ---
    constructor(
        address collateralToken,
        address debtToken,
        uint256 triggerLTV,
        uint256 targetLTV,
    ) {
        s_collateral = IERC20(collateralToken);
        s_debt = IERC20(debtToken);
        s_triggerLTV = triggerLTV;
        s_targetLTV = targetLTV;
    }

    /**
     * @notice Called to check if upkeep is needed
     * @return upkeepNeeded True if conditions met
     * @return performData Payload for performUpkeep (empty here)
     */
    function checkUpkeep(
        bytes calldata /* checkData */
    ) public view override returns (bool upkeepNeeded, bytes memory performData) {
        uint256 currentLTV_ = _currentLTV();
        int256 netInterest_ = _currentNetInterest();

        // Trigger if LTV above threshold OR net interest cost exceeds threshold
        if (currentLTV_ >= s_triggerLTV || netInterest_ < 0) {
            upkeepNeeded = true;
            performData = "";
        } else {
            upkeepNeeded = false;
            performData = "";
        }
    }

    /**
     * @notice Called by keepre/hook/bot to perform the partial debt repayment
     */
    function performUpkeep(bytes calldata /* performData */) external override nonReentrant {
        (bool upkeepNeeded, ) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert("JITpilotKeeper: Upkeep not needed");
        }
        _executePartialRepay();
    }

    // --- Helper functions ---

    /// @dev Returns current LTV
    function _currentLTV() internal view returns (uint256) {
        // IMPLEMENT: Query Eulerswap to get collateral & debt
        // Compute: (debtUSD * 10000) / collateralUSD
        return 0;
    }

     /// @dev Returns net interest
    function _currentNetInterest() internal view returns (int256) {
        // IMPLEMENT: Calculate accrued interest on collateral token
        //          minus accrued interest on debt token
        return 0;
    }

    /// @dev Executes a flash-loan partial repay: borrow collateral, swap to debt, repay, return loan
    function _executePartialRepay() internal {
        // IMPLEMENT:
        // 1. Initiate flash-loan of collateral via Euler
        // 2. Swap needed amount on DEX to debt token
        // 3. Repay debt on Euler to reach target LTV
        // 4. Return flash-loan
    }

}


