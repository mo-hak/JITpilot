// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title JITpilot
 * @dev EulerSwap Just-in-Time liquidity pool rebalancing system
 * Tracks Health Factor and Yield as sliding time-weighted averages over 100 blocks
 */
contract JITpilot {
    // Constants
    uint256 private constant WINDOW_SIZE = 100;
    uint256 private constant PRECISION = 1e18;
    
    // Configurable parameters
    uint256 public rebalanceThreshold = 5e17; // 0.5 in 18 decimals
    uint256 public weightHF = 6e17; // 0.6 weight for Health Factor
    uint256 public weightYield = 4e17; // 0.4 weight for Yield
    
    // Data structure to store block-level data from fetchData
    struct BlockData {
        uint256 allowedLTV;
        uint256 currentLTV;
        uint256 swapFees;
        uint256 netInterest;
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
        address indexed lp,
        uint256 indexed blockNumber,
        uint256 compositeScore,
        uint256 threshold
    );
    
    event LPConfigured(
        address indexed lp,
        uint256 hfMin,
        uint256 hfDesired,
        uint256 yieldTarget
    );
    
    // Modifiers
    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender], "Not authorized");
        _;
    }
    
    constructor() {
        authorizedCallers[msg.sender] = true;
    }
    
    /**
     * @dev Configure LP parameters
     * @param lp LP address
     * @param _hfMin Liquidation threshold
     * @param _hfDesired Target health factor
     * @param _yieldTarget Target yield
     */
    function configureLp(
        address lp,
        uint256 _hfMin,
        uint256 _hfDesired,
        uint256 _yieldTarget
    ) external onlyAuthorized {
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
    function updateMetrics(address lp) external onlyAuthorized {
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
        if (currentData.depositValue > 0) {
            // Handle potential underflow for net interest
            if (currentData.swapFees >= currentData.netInterest) {
                currentYield = ((currentData.swapFees - currentData.netInterest) * PRECISION) / currentData.depositValue;
            } else {
                // Negative yield case
                currentYield = 0; // Set to 0 for simplicity, could handle negative yields differently
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
        emit MetricsUpdated(
            lp,
            block.number,
            currentHF,
            currentYield,
            data.twaHF,
            data.twaYield,
            compositeScore
        );
        
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
    function _normalizeHealthFactor(
        uint256 twaHF,
        uint256 hfMin,
        uint256 hfDesired
    ) internal pure returns (uint256) {
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
        return BlockData({
            allowedLTV: 0,
            currentLTV: 0,
            swapFees: 0,
            netInterest: 0,
            depositValue: 0
        });
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
     * @return LP data struct
     */
    function getLPData(address lp) external view returns (
        uint256 twaHF,
        uint256 twaYield,
        uint256 hfMin,
        uint256 hfDesired,
        uint256 yieldTarget,
        uint256 lastUpdateBlock,
        bool initialized
    ) {
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
}

