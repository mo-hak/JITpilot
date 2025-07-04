// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEulerSwap} from "euler-swap/interfaces/IEulerSwap.sol";
import {IEVault, IERC20} from "evk/EVault/IEVault.sol";
import {IEulerSwapFactory} from "euler-swap/interfaces/IEulerSwapFactory.sol";
import {IMaglevLens} from "src/interfaces/IMaglevLens.sol";
import {IPriceOracle} from "evk/interfaces/IPriceOracle.sol";
import {console2 as console} from "forge-std/console2.sol";

/**
 * @title JITpilot
 * @dev EulerSwap Just-in-Time liquidity pool rebalancing system
 * Tracks Health Factor and Yield as sliding time-weighted averages over 100 blocks
 */
contract JITpilot {
    address public admin;
    address public owner;

    // Constants
    uint256 private constant WINDOW_SIZE = 100;
    uint256 private constant PRECISION = 1e18;

    // Configurable parameters
    uint256 public rebalanceThreshold = 5e17; // 0.5 in 18 decimals
    uint256 public weightHF = 6e17; // 0.6 weight for Health Factor
    uint256 public weightYield = 4e17; // 0.4 weight for Yield

    // Euler contract addresses
    address public EVC;
    address public EVK;
    address public MaglevLens;
    address public EulerSwapFactory;

    // Data structure to store block-level data from fetchData
    struct BlockData {
        uint256 allowedLTV;
        uint256 currentLTV;
        uint256 swapFees;
        int256 netInterest;
        uint256 depositValue;
    }

    // LP data structure
    struct LPData {
        // Health Factor data
        uint256[] hfHistory; // Stores HF values for last 100 blocks
        uint256 twaHF; // Time-weighted average Health Factor
        // Yield data
        uint256[] yieldHistory; // Stores yield values for last 100 blocks
        uint256 twaYield; // Time-weighted average Yield
        // Configuration
        uint256 hfMin; // Liquidation threshold
        uint256 hfDesired; // Target health factor set by LP
        uint256 yieldTarget; // Target yield set by LP
        // Tracking
        uint256 lastUpdateBlock; // Last block when metrics were updated
        uint256 startBlock; // Block when LP started
        bool initialized; // Whether LP data is initialized
    }

    // Mappings
    mapping(address => LPData) public lpData;
    mapping(address => bool) public authorizedCallers;

    // Events
    event MetricsUpdated(
        address indexed lp,
        uint256 indexed blockNumber,
        uint256 healthFactor,
        uint256 yield,
        uint256 twaHF,
        uint256 twaYield,
        uint256 compositeScore
    );

    event RebalanceTriggered(
        address indexed lp, uint256 indexed blockNumber, uint256 compositeScore, uint256 threshold
    );

    event LPConfigured(address indexed lp, uint256 hfMin, uint256 hfDesired, uint256 yieldTarget);

    // Modifiers
    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender], "Not authorized");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        authorizedCallers[msg.sender] = true;
        admin = msg.sender;
        owner = msg.sender;
    }

    // Setters for contract addresses
    function setEVC(address _EVC) external onlyOwner {
        EVC = _EVC;
    }

    function setEVK(address _EVK) external onlyOwner {
        EVK = _EVK;
    }

    function setMaglevLens(address _MaglevLens) external onlyOwner {
        MaglevLens = _MaglevLens;
    }

    function setEulerSwapFactory(address _EulerSwapFactory) external onlyOwner {
        EulerSwapFactory = _EulerSwapFactory;
    }

    /**
     * @dev Configure LP parameters
     * @param lp LP address
     * @param _hfMin Liquidation threshold
     * @param _hfDesired Target health factor
     * @param _yieldTarget Target yield
     */
    function configureLp(address lp, uint256 _hfMin, uint256 _hfDesired, uint256 _yieldTarget) external {
        require(lp != address(0), "Invalid LP address");
        require(_hfDesired > _hfMin, "HF desired must be > HF min");

        LPData storage data = lpData[lp];
        data.hfMin = _hfMin;
        data.hfDesired = _hfDesired;
        data.yieldTarget = _yieldTarget;
        data.initialized = true;
        data.startBlock = block.number;

        emit LPConfigured(lp, _hfMin, _hfDesired, _yieldTarget);
    }

    /**
     * @dev Update metrics for a specific LP
     * @param lp LP address to update metrics for
     */
    function updateMetrics(address lp) external {
        require(lpData[lp].initialized, "LP not configured");

        LPData storage data = lpData[lp];

        // Fetch current block data
        BlockData memory currentData = fetchData(lp);

        // Calculate current Health Factor
        uint256 currentHF = 0;
        if (currentData.currentLTV > 0) {
            currentHF = (currentData.allowedLTV * PRECISION) / currentData.currentLTV;
        }

        // Calculate current Yield
        uint256 currentYield = 0;
        uint256 swapApy = currentData.swapFees / currentData.depositValue;
        if (currentData.depositValue > 0) {
            if (currentData.netInterest >= 0) {
                currentYield = (uint256(currentData.netInterest) * PRECISION) + swapApy;
            } else if (swapApy >= uint256(currentData.netInterest)) {
                // netInterest is negative, but swapApy is greater, so yield is positive.
                currentYield = swapApy - uint256(currentData.netInterest);
            } else {
                // Yield is negative. Set to 0 for simplicity.
                currentYield = 0;
            }
        }

        // Update sliding window for Health Factor
        _updateSlidingWindow(data.hfHistory, currentHF);

        // Update sliding window for Yield
        _updateSlidingWindow(data.yieldHistory, currentYield);

        // Calculate TWA for Health Factor
        data.twaHF = _calculateTWA(data.hfHistory, data.startBlock);

        // Calculate TWA for Yield
        data.twaYield = _calculateTWA(data.yieldHistory, data.startBlock);

        // Calculate normalized values
        uint256 normalizedHF = _normalizeHealthFactor(data.twaHF, data.hfMin, data.hfDesired);
        uint256 normalizedYield = _normalizeYield(data.twaYield, data.yieldTarget);

        // Calculate composite score
        uint256 compositeScore = (weightHF * normalizedHF + weightYield * normalizedYield) / PRECISION;

        // Update last update block
        data.lastUpdateBlock = block.number;

        // Emit metrics updated event
        emit MetricsUpdated(lp, block.number, currentHF, currentYield, data.twaHF, data.twaYield, compositeScore);

        // Check if rebalancing is needed
        if (compositeScore < rebalanceThreshold) {
            emit RebalanceTriggered(lp, block.number, compositeScore, rebalanceThreshold);
            rebalance(lp);
        }
    }

    /**
     * @dev Update sliding window array with new value
     * @param history Array storing historical values
     * @param newValue New value to add
     */
    function _updateSlidingWindow(uint256[] storage history, uint256 newValue) internal {
        if (history.length < WINDOW_SIZE) {
            // Still filling the initial window
            history.push(newValue);
        } else {
            // Sliding window - remove oldest, add newest
            for (uint256 i = 0; i < WINDOW_SIZE - 1; i++) {
                history[i] = history[i + 1];
            }
            history[WINDOW_SIZE - 1] = newValue;
        }
    }

    /**
     * @dev Calculate time-weighted average
     * @param history Array of historical values
     * @param startBlock Block when LP started
     * @return TWA value
     */
    function _calculateTWA(uint256[] storage history, uint256 startBlock) internal view returns (uint256) {
        uint256 length = history.length;
        if (length == 0) return 0;

        // Calculate blocks elapsed since start
        uint256 blocksElapsed = block.number - startBlock + 1;

        // Determine effective window size
        uint256 effectiveWindow = blocksElapsed <= WINDOW_SIZE ? blocksElapsed : WINDOW_SIZE;

        uint256 sum = 0;
        for (uint256 i = 0; i < length; i++) {
            sum += history[i];
        }

        return sum / effectiveWindow;
    }

    /**
     * @dev Normalize Health Factor to [0,1] range
     * @param twaHF Time-weighted average Health Factor
     * @param hfMin Minimum health factor (liquidation threshold)
     * @param hfDesired Desired health factor
     * @return Normalized HF value
     */
    function _normalizeHealthFactor(uint256 twaHF, uint256 hfMin, uint256 hfDesired) internal pure returns (uint256) {
        if (twaHF <= hfMin) return 0;
        if (twaHF >= hfDesired) return PRECISION;

        return ((twaHF - hfMin) * PRECISION) / (hfDesired - hfMin);
    }

    /**
     * @dev Normalize Yield to [0,1] range
     * @param twaYield Time-weighted average yield
     * @param yieldTarget Target yield
     * @return Normalized yield value
     */
    function _normalizeYield(uint256 twaYield, uint256 yieldTarget) internal pure returns (uint256) {
        if (yieldTarget == 0) return PRECISION; // Avoid division by zero
        if (twaYield >= yieldTarget) return PRECISION;

        return (twaYield * PRECISION) / yieldTarget;
    }

    /**
     * @dev Fetch current block data (placeholder - to be implemented later)
     * @param lp LP address
     * @return BlockData struct with current metrics
     */
    function fetchData(address lp) internal view returns (BlockData memory) {
        // Placeholder implementation - this will fetch real data from Euler contracts
        // For now, return dummy data to avoid compilation errors

        // get LP's eulerSwap pool address
        address poolAddr = IEulerSwapFactory(EulerSwapFactory).poolByEulerAccount(lp);

        // get eulerSwap pool data
        EulerSwapData memory eulerSwapData = getEulerSwapData(poolAddr);

        BlockData memory blockData;

        blockData.allowedLTV = 0;
        blockData.currentLTV = 0;
        blockData.swapFees = 0;
        blockData.netInterest = 0;
        blockData.depositValue = 0;

        // uint256 swapFees = 0;
        uint256 supplyApyTotal = 0;
        uint256 borrowApyTotal = 0;

        // We only consider the EulerSwap vaults as collateral for this account, even if
        // they have other enabled collaterals. This may differ from Euler's own UI, but it's
        // more accurate for our purposes.
        // uint256 collateralValue0 = getCollateralValue(lp, vault0);
        // uint256 collateralValue1 = getCollateralValue(lp, vault1);
        uint256 collateralValueTotal =
            getCollateralValue(lp, eulerSwapData.params.vault0) + getCollateralValue(lp, eulerSwapData.params.vault1);

        // get supply APY data using the MaglevLens contract
        IMaglevLens maglevLens = IMaglevLens(MaglevLens);
        address[] memory collateralVaults = new address[](2);
        collateralVaults[0] = eulerSwapData.params.vault0;
        collateralVaults[1] = eulerSwapData.params.vault1;
        IMaglevLens.VaultGlobal[] memory collateralVaultsGlobal = maglevLens.vaultsGlobal(collateralVaults);
        // packed2: shares (160), supply APY (48), borrow APY (48)
        for (uint256 i; i < collateralVaultsGlobal.length; ++i) {
            uint256 supplyApy = uint256((collateralVaultsGlobal[i].packed2 << (256 - 96)) >> (256 - 48));
            supplyApyTotal += supplyApy * getCollateralValue(lp, collateralVaults[i]) / collateralValueTotal;
            console.log("Supply APY for vault", collateralVaults[i], "is", supplyApy);
            console.log("Supply APY total is", supplyApyTotal);
        }

        // get the currently enabled controller vault (i.e. the debt vault)
        address controllerVault = getCurrentControllerVault(lp);

        // If there is no controller, there is no debt, and no liquidation metrics to calculate
        if (controllerVault == address(0)) {
            console.log("doesn't have controller vault: ", controllerVault);
            blockData.allowedLTV = 0;
            blockData.currentLTV = 0;
            // If there is no debt, there is no looping or leverage
            blockData.depositValue = collateralValueTotal;
            blockData.netInterest = int256(supplyApyTotal);
        } else {
            console.log("has controller vault: ", controllerVault);
            // Figure out which vault is the collateralVault
            address collateralVault = (controllerVault == eulerSwapData.params.vault0)
                ? eulerSwapData.params.vault1
                : eulerSwapData.params.vault0;
            uint256 debtValue = getDebtValue(lp, controllerVault);
            console.log("debtValue: ", debtValue);
            blockData.allowedLTV = uint256(IEVault(controllerVault).LTVLiquidation(collateralVault)) * 1e18 / 1e4;
            blockData.currentLTV = debtValue * 1e18 / collateralValueTotal;
            console.log("currentLTV: ", blockData.currentLTV);

            address[] memory controllerVaultArray = new address[](1);
            controllerVaultArray[0] = controllerVault;
            IMaglevLens.VaultGlobal[] memory controllerVaultsGlobal = maglevLens.vaultsGlobal(controllerVaultArray);
            // borrow APY is on the last 48 bits. Shift left then right to extract it.
            uint256 borrowApy = uint256((controllerVaultsGlobal[0].packed2 << (256 - 48)) >> (256 - 48));
            borrowApyTotal = borrowApy;

            // The EVC already ensures that liabilityValue is less than collateralValueTotal, so this is safe
            blockData.depositValue = collateralValueTotal - debtValue;
            if (supplyApyTotal * collateralValueTotal < borrowApyTotal * debtValue) {
                // avoid overflow
                blockData.netInterest = -int256((borrowApyTotal * debtValue - supplyApyTotal * collateralValueTotal) / blockData.depositValue)
                    * 1e9;
            } else {
                blockData.netInterest = int256(
                    (supplyApyTotal * collateralValueTotal - borrowApyTotal * debtValue) / blockData.depositValue
                ) * 1e9;
            }
        }

        // get LP's liquidity status in the controller vault, with regards to liquidation
        // (
        //     address[] memory collateralVaults,
        //     uint256[] memory collateralValues,
        //     uint256 liabilityValue
        // ) = IEVault(controllerVault).accountLiquidityFull(lp, true);

        // these collateralValues are adjusted to LTV. We need to divide by liquidationLTV to get the non-adjusted LTV
        // uint256 collateralValueTotal;
        // uint256 allowedLTV = 0; // Will be weighted average of all collateral LTVs
        // uint256 totalWeight = 0;
        // for (uint256 i; i < collateralVaults.length; ++i) {
        //     uint16 ltv = IEVault(controllerVault).LTVLiquidation(collateralVaults[i]);
        //     collateralValues[i] = collateralValues[i] * 10000 / ltv; // Convert back to non-adjusted value
        //     collateralValueTotal += collateralValues[i];

        //     // Calculate weighted average LTV
        //     allowedLTV += ltv * collateralValues[i];
        //     totalWeight += collateralValues[i];
        // }

        // Finalize weighted average LTV
        // if (totalWeight > 0) {
        //     allowedLTV = allowedLTV / totalWeight;
        // }

        // #2 calculate the currentLTV
        // uint256 currentLTV = liabilityValue / collateralValueTotal;

        // TODO: get swap fees
        // uint256 swapFees = 0;

        // uint256 borrowApy = uint256((controllerVaultGlobals[0].packed2 << (256 - 48)) >> (256 - 48));

        // #4 calculate net interest
        // uint256 netInterest = supplyApyTotal - borrowApy;

        // #5 get the depositValue
        // uint256 depositValue = collateralValueTotal - liabilityValue;

        return blockData;
    }

    struct EulerSwapData {
        address addr;
        IEulerSwap.Params params;
        address asset0;
        address asset1;
        uint256 reserve0;
        uint256 reserve1;
        uint256 inLimit01;
        uint256 outLimit01;
        uint256 inLimit10;
        uint256 outLimit10;
    }

    function getEulerSwapData(address poolAddr) internal view returns (EulerSwapData memory output) {
        IEulerSwap pool = IEulerSwap(poolAddr);
        output.addr = poolAddr;
        output.params = pool.getParams();
        {
            (uint112 reserve0, uint112 reserve1,) = pool.getReserves();
            output.reserve0 = reserve0;
            output.reserve1 = reserve1;
        }
        (address asset0, address asset1) = pool.getAssets();
        output.asset0 = asset0;
        output.asset1 = asset1;
        (output.inLimit01, output.outLimit01) = pool.getLimits(asset0, asset1);
        (output.inLimit10, output.outLimit10) = pool.getLimits(asset1, asset0);
    }
    /**
     * @dev Rebalance LP position (placeholder - to be implemented later)
     * @param lp LP address to rebalance
     */

    function rebalance(address lp) internal {
        // Placeholder implementation - this will perform actual rebalancing
        // Will be implemented in later iterations
    }

    /**
     * @dev Add authorized caller
     * @param caller Address to authorize
     */
    function addAuthorizedCaller(address caller) external onlyAuthorized {
        authorizedCallers[caller] = true;
    }

    /**
     * @dev Remove authorized caller
     * @param caller Address to remove authorization
     */
    function removeAuthorizedCaller(address caller) external onlyAuthorized {
        authorizedCallers[caller] = false;
    }

    /**
     * @dev Update rebalance threshold
     * @param newThreshold New threshold value
     */
    function updateRebalanceThreshold(uint256 newThreshold) external onlyAuthorized {
        require(newThreshold <= PRECISION, "Threshold too high");
        rebalanceThreshold = newThreshold;
    }

    /**
     * @dev Update weights for composite score
     * @param newWeightHF New weight for Health Factor
     * @param newWeightYield New weight for Yield
     */
    function updateWeights(uint256 newWeightHF, uint256 newWeightYield) external onlyAuthorized {
        require(newWeightHF + newWeightYield == PRECISION, "Weights must sum to 1");
        weightHF = newWeightHF;
        weightYield = newWeightYield;
    }

    /**
     * @dev Get LP data for viewing
     * @param lp LP address
     * @return twaHF Time-weighted average Health Factor
     * @return twaYield Time-weighted average Yield
     * @return hfMin Liquidation threshold
     * @return hfDesired Target health factor
     * @return yieldTarget Target yield
     * @return lastUpdateBlock Last block when metrics were updated
     * @return initialized Whether LP data is initialized
     */
    function getLPData(address lp)
        external
        view
        returns (
            uint256 twaHF,
            uint256 twaYield,
            uint256 hfMin,
            uint256 hfDesired,
            uint256 yieldTarget,
            uint256 lastUpdateBlock,
            bool initialized
        )
    {
        LPData storage data = lpData[lp];
        return (
            data.twaHF,
            data.twaYield,
            data.hfMin,
            data.hfDesired,
            data.yieldTarget,
            data.lastUpdateBlock,
            data.initialized
        );
    }

    /**
     * @dev Get current composite score for an LP
     * @param lp LP address
     * @return Composite score
     */
    function getCompositeScore(address lp) external view returns (uint256) {
        LPData storage data = lpData[lp];
        if (!data.initialized) return 0;

        uint256 normalizedHF = _normalizeHealthFactor(data.twaHF, data.hfMin, data.hfDesired);
        uint256 normalizedYield = _normalizeYield(data.twaYield, data.yieldTarget);

        return (weightHF * normalizedHF + weightYield * normalizedYield) / PRECISION;
    }

    // HELPER FUNCTIONS

    function getCurrentControllerVault(address lp) internal view returns (address) {
        address[] memory controllerVaults = IEVC(EVC).getControllers(lp);
        address currentControllerVault;

        if (controllerVaults.length == 0) return address(0);

        // find which of the LP's controller vaults is the enabled debt vault
        for (uint256 i; i < controllerVaults.length; ++i) {
            if (IEVC(EVC).isControllerEnabled(lp, controllerVaults[i])) {
                currentControllerVault = controllerVaults[i];
                break;
            }
        }
        return currentControllerVault;
    }

    function getCollateralValue(address account, address collateral) internal view virtual returns (uint256 value) {
        IEVault collateralVault = IEVault(collateral);
        uint256 balance = IERC20(collateral).balanceOf(account);
        if (balance == 0) return 0;

        uint256 currentCollateralValue;

        // mid-point price
        currentCollateralValue =
            IPriceOracle(collateralVault.oracle()).getQuote(balance, collateral, collateralVault.unitOfAccount());

        return currentCollateralValue;
    }

    function getDebtValue(address account, address vault) internal view virtual returns (uint256 value) {
        IEVault controllerVault = IEVault(vault);
        uint256 debt = controllerVault.debtOf(account);
        if (debt == 0) return 0;

        uint256 currentDebtValue;

        // mid-point price
        currentDebtValue = IPriceOracle(controllerVault.oracle()).getQuote(debt, vault, controllerVault.unitOfAccount());

        return currentDebtValue;
    }

    function getData(address lp) external view returns (BlockData memory) {
        return fetchData(lp);
    }
}
