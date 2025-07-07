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

// Reuse mock contracts from main test file
import "./JITpilot.t.sol";

contract JITpilotIntegrationTest is Test {
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

    address public constant LP_ADDRESS_1 = address(0x1111);
    address public constant LP_ADDRESS_2 = address(0x2222);
    address public constant LP_ADDRESS_3 = address(0x3333);

    uint256 public constant HF_MIN = 11e17; // 1.1
    uint256 public constant HF_DESIRED = 15e17; // 1.5

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

        // Set up mock EulerSwap
        IEulerSwap.Params memory params = IEulerSwap.Params({
            vault0: address(mockVault0),
            vault1: address(mockVault1),
            eulerAccount: address(0), // Will be set per LP
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

        // Set up pools for each LP
        _setupLPPool(LP_ADDRESS_1, params);
        _setupLPPool(LP_ADDRESS_2, params);
        _setupLPPool(LP_ADDRESS_3, params);

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

        // Set up price oracle
        mockOracle.setPrice(1e18, address(mockToken0), address(mockToken0), 1e18);
        mockOracle.setPrice(1e18, address(mockToken1), address(mockToken1), 1e18);

        // Set up MaglevLens response
        IMaglevLens.VaultGlobal memory globalData = IMaglevLens.VaultGlobal({
            packed1: 0,
            packed2: (uint256(5e16) << 48) | (uint256(3e16) << 96) // supply APY 5%, borrow APY 3%
        });
        mockLens.setVaultGlobal(address(mockVault0), globalData);
        mockLens.setVaultGlobal(address(mockVault1), globalData);
    }

    function _setupLPPool(address lpAddress, IEulerSwap.Params memory baseParams) internal {
        IEulerSwap.Params memory params = baseParams;
        params.eulerAccount = lpAddress;
        mockEulerSwap.setParams(params);
        mockFactory.setPool(lpAddress, address(mockEulerSwap));

        // Set up controller
        address[] memory controllers = new address[](1);
        controllers[0] = address(mockVault0);
        mockEVC.setControllers(lpAddress, controllers);
        mockEVC.setControllerEnabled(lpAddress, address(mockVault0), true);
    }

    // function test_MultipleLP_Configuration() public {
    //     // Configure multiple LPs with different parameters
    //     jitpilot.configureLp(LP_ADDRESS_1, HF_MIN, HF_DESIRED);
    //     jitpilot.configureLp(LP_ADDRESS_2, 12e17, 16e17); // Different parameters
    //     jitpilot.configureLp(LP_ADDRESS_3, 105e16, 14e17); // Different parameters

    //     // Verify each LP has correct configuration
    //     (,, uint256 hfMin1, uint256 hfDesired1,,,,,,, bool init1,) = jitpilot.getLPData(LP_ADDRESS_1);
    //     (,, uint256 hfMin2, uint256 hfDesired2,,,,,,, bool init2,) = jitpilot.getLPData(LP_ADDRESS_2);
    //     (,, uint256 hfMin3, uint256 hfDesired3,,,,,,, bool init3,) = jitpilot.getLPData(LP_ADDRESS_3);

    //     assertTrue(init1 && init2 && init3);
    //     assertEq(hfMin1, HF_MIN);
    //     assertEq(hfDesired1, HF_DESIRED);
    //     assertEq(hfMin2, 12e17);
    //     assertEq(hfDesired2, 16e17);
    //     assertEq(hfMin3, 105e16);
    //     assertEq(hfDesired3, 14e17);
    // }
}
