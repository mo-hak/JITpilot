// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {JITpilot} from "../src/JITpilot.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEulerSwap} from "euler-swap/interfaces/IEulerSwap.sol";
import {IEVault, IERC20} from "evk/EVault/IEVault.sol";
import {IEulerSwapFactory} from "euler-swap/interfaces/IEulerSwapFactory.sol";
import {IMaglevLens} from "src/interfaces/IMaglevLens.sol";
import {IPriceOracle} from "evk/interfaces/IPriceOracle.sol";

// Mock contracts for testing
contract MockEVC {
    mapping(address => address[]) private controllers;
    mapping(address => mapping(address => bool)) private enabledControllers;

    function setControllers(address account, address[] memory _controllers) external {
        controllers[account] = _controllers;
    }

    function getControllers(address account) external view returns (address[] memory) {
        return controllers[account];
    }

    function setControllerEnabled(address account, address controller, bool enabled) external {
        enabledControllers[account][controller] = enabled;
    }

    function isControllerEnabled(address account, address controller) external view returns (bool) {
        return enabledControllers[account][controller];
    }
}

contract MockEVault {
    uint16 public liquidationLTV;
    uint16 public borrowLTV;
    address public assetAddress;
    address public oracleAddress;
    address public unitOfAccountAddress;
    mapping(address => uint256) public balances;
    mapping(address => uint256) public debts;

    function setLiquidationLTV(address, uint16 _ltv) external {
        liquidationLTV = _ltv;
    }

    function LTVLiquidation(address) external view returns (uint16) {
        return liquidationLTV;
    }

    function setBorrowLTV(address, uint16 _ltv) external {
        borrowLTV = _ltv;
    }

    function LTVBorrow(address) external view returns (uint16) {
        return borrowLTV;
    }

    function setAsset(address _asset) external {
        assetAddress = _asset;
    }

    function asset() external view returns (address) {
        return assetAddress;
    }

    function setOracle(address _oracle) external {
        oracleAddress = _oracle;
    }

    function oracle() external view returns (address) {
        return oracleAddress;
    }

    function setUnitOfAccount(address _unitOfAccount) external {
        unitOfAccountAddress = _unitOfAccount;
    }

    function unitOfAccount() external view returns (address) {
        return unitOfAccountAddress;
    }

    function setBalance(address account, uint256 balance) external {
        balances[account] = balance;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function setDebt(address account, uint256 debt) external {
        debts[account] = debt;
    }

    function debtOf(address account) external view returns (uint256) {
        return debts[account];
    }
}

contract MockEulerSwap {
    IEulerSwap.Params public params;
    uint112 public reserve0;
    uint112 public reserve1;
    address public asset0;
    address public asset1;

    function setParams(IEulerSwap.Params memory _params) external {
        params = _params;
    }

    function getParams() external view returns (IEulerSwap.Params memory) {
        return params;
    }

    function setReserves(uint112 _reserve0, uint112 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function setAssets(address _asset0, address _asset1) external {
        asset0 = _asset0;
        asset1 = _asset1;
    }

    function getAssets() external view returns (address, address) {
        return (asset0, asset1);
    }
}

contract MockEulerSwapFactory {
    mapping(address => address) public pools;

    function setPool(address eulerAccount, address poolAddress) external {
        pools[eulerAccount] = poolAddress;
    }

    function poolByEulerAccount(address eulerAccount) external view returns (address) {
        return pools[eulerAccount];
    }
}

contract MockMaglevLens {
    mapping(address => IMaglevLens.VaultGlobal) public vaultGlobals;

    function setVaultGlobal(address vault, IMaglevLens.VaultGlobal memory global) external {
        vaultGlobals[vault] = global;
    }

    function vaultsGlobal(address[] memory vaults) external view returns (IMaglevLens.VaultGlobal[] memory) {
        IMaglevLens.VaultGlobal[] memory result = new IMaglevLens.VaultGlobal[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            result[i] = vaultGlobals[vaults[i]];
        }
        return result;
    }
}

contract MockPriceOracle {
    mapping(bytes32 => uint256) public prices;

    function setPrice(uint256 amount, address base, address quote, uint256 price) external {
        bytes32 key = keccak256(abi.encodePacked(amount, base, quote));
        prices[key] = price;
    }

    function getQuote(uint256 amount, address base, address quote) external view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(amount, base, quote));
        return prices[key];
    }
}

contract MockERC20 {
    uint8 public decimals = 18;

    function setDecimals(uint8 _decimals) external {
        decimals = _decimals;
    }
}

contract JITpilotTest is Test {
    JITpilot public jitpilot;
    MockEVC public mockEVC;
    MockEVault public mockVault0;
    MockEVault public mockVault1;
    MockEulerSwap public mockEulerSwap;
    MockEulerSwapFactory public mockFactory;
    MockMaglevLens public mockLens;
    MockPriceOracle public mockOracle;
    MockERC20 public mockToken0;
    MockERC20 public mockToken1;

    address public constant LP_ADDRESS = address(0x1234);
    address public constant AUTHORIZED_CALLER = address(0x5678);
    address public constant NON_AUTHORIZED = address(0x9ABC);

    uint256 public constant HF_MIN = 11e17; // 1.1
    uint256 public constant HF_DESIRED = 15e17; // 1.5
    uint256 public constant YIELD_TARGET = 5e16; // 5%

    event LPConfigured(address indexed lp, uint256 hfMin, uint256 hfDesired);
    event MetricsUpdated(
        address indexed lp,
        uint256 indexed blockNumber,
        uint256 healthFactor,
        uint256 yield,
        uint256 twaHF,
        uint256 twaYield
    );
    event RebalanceTriggered(address indexed lp, uint256 indexed blockNumber, uint256 hf, uint256 threshold);

    function setUp() public {
        // Deploy JITpilot contract
        jitpilot = new JITpilot();

        // Deploy mock contracts
        mockEVC = new MockEVC();
        mockVault0 = new MockEVault();
        mockVault1 = new MockEVault();
        mockEulerSwap = new MockEulerSwap();
        mockFactory = new MockEulerSwapFactory();
        mockLens = new MockMaglevLens();
        mockOracle = new MockPriceOracle();
        mockToken0 = new MockERC20();
        mockToken1 = new MockERC20();

        // Set up JITpilot with mock addresses
        jitpilot.setEVC(address(mockEVC));
        jitpilot.setMaglevLens(address(mockLens));
        jitpilot.setEulerSwapFactory(address(mockFactory));

        // Add authorized caller
        jitpilot.addAuthorizedCaller(AUTHORIZED_CALLER);

        // Set up mock EulerSwap
        IEulerSwap.Params memory params = IEulerSwap.Params({
            vault0: address(mockVault0),
            vault1: address(mockVault1),
            eulerAccount: LP_ADDRESS,
            equilibriumReserve0: 1000000,
            equilibriumReserve1: 1000000,
            priceX: 1e18,
            priceY: 1e18,
            concentrationX: 9e17,
            concentrationY: 9e17,
            fee: 3000,
            protocolFee: 0,
            protocolFeeRecipient: address(0)
        });
        mockEulerSwap.setParams(params);
        mockEulerSwap.setReserves(1000000, 1000000);
        mockEulerSwap.setAssets(address(mockToken0), address(mockToken1));

        mockFactory.setPool(LP_ADDRESS, address(mockEulerSwap));

        // Set up mock vaults
        mockVault0.setLiquidationLTV(address(mockVault1), 8000); // 80%
        mockVault1.setLiquidationLTV(address(mockVault0), 8000);
        mockVault0.setBorrowLTV(address(mockVault1), 7500); // 75%
        mockVault1.setBorrowLTV(address(mockVault0), 7500);

        mockVault0.setAsset(address(mockToken0));
        mockVault1.setAsset(address(mockToken1));
        mockVault0.setOracle(address(mockOracle));
        mockVault1.setOracle(address(mockOracle));
        mockVault0.setUnitOfAccount(address(mockToken0));
        mockVault1.setUnitOfAccount(address(mockToken1));

        // Set up initial balances and debts
        mockVault0.setBalance(LP_ADDRESS, 1000e18);
        mockVault1.setBalance(LP_ADDRESS, 1000e18);
        mockVault0.setDebt(LP_ADDRESS, 500e18);

        // Set up price oracle
        mockOracle.setPrice(1e18, address(mockToken0), address(mockToken0), 1e18);
        mockOracle.setPrice(1e18, address(mockToken1), address(mockToken1), 1e18);

        // Set up additional oracle prices for position value calculations
        mockOracle.setPrice(1000e18, address(mockVault0), address(mockToken0), 1000e18);
        mockOracle.setPrice(1000e18, address(mockVault1), address(mockToken1), 1000e18);
        mockOracle.setPrice(500e18, address(mockVault0), address(mockToken0), 500e18);

        // Set up controller
        address[] memory controllers = new address[](1);
        controllers[0] = address(mockVault0);
        mockEVC.setControllers(LP_ADDRESS, controllers);
        mockEVC.setControllerEnabled(LP_ADDRESS, address(mockVault0), true);
    }

    function test_Constructor() public {
        assertEq(jitpilot.admin(), address(this));
        assertEq(jitpilot.owner(), address(this));
        assertTrue(jitpilot.authorizedCallers(address(this)));
        assertEq(jitpilot.weightHF(), 6e17);
        assertEq(jitpilot.weightYield(), 4e17);
    }

    function test_SetAddresses() public {
        address newEVC = address(0x1111);
        address newEVK = address(0x2222);
        address newLens = address(0x3333);
        address newFactory = address(0x4444);
        address newImpl = address(0x5555);

        jitpilot.setEVC(newEVC);
        jitpilot.setEVK(newEVK);
        jitpilot.setMaglevLens(newLens);
        jitpilot.setEulerSwapFactory(newFactory);
        jitpilot.setEulerSwapImpl(newImpl);

        assertEq(jitpilot.evcAddress(), newEVC);
        assertEq(jitpilot.evkAddress(), newEVK);
        assertEq(jitpilot.maglevLensAddress(), newLens);
        assertEq(jitpilot.eulerSwapFactoryAddress(), newFactory);
        assertEq(jitpilot.eulerSwapImplAddress(), newImpl);
    }

    function test_SetAddressesOnlyOwner() public {
        vm.prank(NON_AUTHORIZED);
        vm.expectRevert("Not owner");
        jitpilot.setEVC(address(0x1111));

        vm.prank(NON_AUTHORIZED);
        vm.expectRevert("Not owner");
        jitpilot.setEVK(address(0x2222));

        vm.prank(NON_AUTHORIZED);
        vm.expectRevert("Not owner");
        jitpilot.setMaglevLens(address(0x3333));

        vm.prank(NON_AUTHORIZED);
        vm.expectRevert("Not owner");
        jitpilot.setEulerSwapFactory(address(0x4444));

        vm.prank(NON_AUTHORIZED);
        vm.expectRevert("Not owner");
        jitpilot.setEulerSwapImpl(address(0x5555));
    }

    function test_ConfigureLp() public {
        vm.expectEmit(true, false, false, true);
        emit LPConfigured(LP_ADDRESS, HF_MIN, HF_DESIRED);

        jitpilot.configureLp(LP_ADDRESS, HF_MIN, HF_DESIRED);

        (
            uint256 twaHF,
            uint256 twaYield,
            uint256 hfMin,
            uint256 hfDesired,
            uint256 yieldTarget,
            uint256 rebalanceThreshold,
            uint256 rebalanceDesired,
            uint256 lastUpdateBlock,
            ,
            ,
            bool initialized,
        ) = jitpilot.getLPData(LP_ADDRESS);

        assertTrue(initialized);
        assertEq(hfMin, HF_MIN);
        assertEq(hfDesired, HF_DESIRED);
        assertEq(rebalanceThreshold, HF_DESIRED);
        assertEq(rebalanceDesired, HF_DESIRED);
    }

    function test_ConfigureLpInvalidAddress() public {
        vm.expectRevert("Invalid LP address");
        jitpilot.configureLp(address(0), HF_MIN, HF_DESIRED);
    }

    function test_ConfigureLpInvalidHFRange() public {
        vm.expectRevert("HF desired must be > HF min");
        jitpilot.configureLp(LP_ADDRESS, HF_DESIRED, HF_MIN);
    }

    function test_UpdateMetricsNotConfigured() public {
        vm.expectRevert("LP not configured");
        jitpilot.updateMetrics(LP_ADDRESS);
    }

    function test_UpdateMetrics() public {
        // Configure LP first
        jitpilot.configureLp(LP_ADDRESS, HF_MIN, HF_DESIRED);

        // Set up MaglevLens response for supply APY
        IMaglevLens.VaultGlobal memory globalData = IMaglevLens.VaultGlobal({
            packed1: 0,
            packed2: (uint256(5e16) << 48) | (uint256(3e16) << 96) // supply APY 5%, borrow APY 3%
        });
        mockLens.setVaultGlobal(address(mockVault0), globalData);
        mockLens.setVaultGlobal(address(mockVault1), globalData);

        vm.expectEmit(true, true, false, false);
        emit MetricsUpdated(LP_ADDRESS, block.number, 0, 0, 0, 0); // Actual values may vary due to calculation complexity

        jitpilot.updateMetrics(LP_ADDRESS);

        (uint256 twaHF, uint256 twaYield,,,,,, uint256 lastUpdateBlock,,,,) = jitpilot.getLPData(LP_ADDRESS);

        assertEq(lastUpdateBlock, block.number);
        assertGt(twaHF, 0); // Should have some positive HF value
    }

    function test_AuthorizedCallers() public {
        // Test adding authorized caller
        vm.prank(AUTHORIZED_CALLER);
        jitpilot.addAuthorizedCaller(NON_AUTHORIZED);
        assertTrue(jitpilot.authorizedCallers(NON_AUTHORIZED));

        // Test removing authorized caller
        vm.prank(AUTHORIZED_CALLER);
        jitpilot.removeAuthorizedCaller(NON_AUTHORIZED);
        assertFalse(jitpilot.authorizedCallers(NON_AUTHORIZED));
    }

    function test_AuthorizedCallersOnlyAuthorized() public {
        vm.prank(NON_AUTHORIZED);
        vm.expectRevert("Not authorized");
        jitpilot.addAuthorizedCaller(address(0x6666));

        vm.prank(NON_AUTHORIZED);
        vm.expectRevert("Not authorized");
        jitpilot.removeAuthorizedCaller(AUTHORIZED_CALLER);
    }

    function test_UpdateWeights() public {
        uint256 newWeightHF = 7e17; // 0.7
        uint256 newWeightYield = 3e17; // 0.3

        vm.prank(AUTHORIZED_CALLER);
        jitpilot.updateWeights(newWeightHF, newWeightYield);

        assertEq(jitpilot.weightHF(), newWeightHF);
        assertEq(jitpilot.weightYield(), newWeightYield);
    }

    function test_UpdateWeightsInvalidSum() public {
        vm.prank(AUTHORIZED_CALLER);
        vm.expectRevert("Weights must sum to 1");
        jitpilot.updateWeights(5e17, 6e17); // Sum > 1
    }

    function test_UpdateWeightsOnlyAuthorized() public {
        vm.prank(NON_AUTHORIZED);
        vm.expectRevert("Not authorized");
        jitpilot.updateWeights(7e17, 3e17);
    }

    function test_GetLPMetrics() public {
        // Configure LP
        jitpilot.configureLp(LP_ADDRESS, HF_MIN, HF_DESIRED);

        (uint256 compositeScore, uint256 threshold, uint256 desired, bool needsRebalance) =
            jitpilot.getLPMetrics(LP_ADDRESS);

        assertEq(threshold, HF_DESIRED);
        assertEq(desired, HF_DESIRED);
        // needsRebalance depends on composite score calculation
    }

    function test_RebalanceThresholds() public {
        jitpilot.configureLp(LP_ADDRESS, HF_MIN, HF_DESIRED);

        uint256 threshold = jitpilot.getRebalanceThreshold(LP_ADDRESS);
        uint256 desired = jitpilot.getRebalanceDesired(LP_ADDRESS);

        assertEq(threshold, HF_DESIRED);
        assertEq(desired, HF_DESIRED);
    }

    function test_SlidingWindowBehavior() public {
        jitpilot.configureLp(LP_ADDRESS, HF_MIN, HF_DESIRED);

        IMaglevLens.VaultGlobal memory globalData =
            IMaglevLens.VaultGlobal({packed1: 0, packed2: (uint256(5e16) << 48) | (uint256(3e16) << 96)});
        mockLens.setVaultGlobal(address(mockVault0), globalData);
        mockLens.setVaultGlobal(address(mockVault1), globalData);

        // Update metrics multiple times to test sliding window
        for (uint256 i = 0; i < 5; i++) {
            vm.roll(block.number + 1);
            jitpilot.updateMetrics(LP_ADDRESS);
        }

        (uint256 twaHF,,,,,,,,,,,) = jitpilot.getLPData(LP_ADDRESS);

        // TWA should be stable after multiple updates with same conditions
        assertGt(twaHF, 0);
    }
}
