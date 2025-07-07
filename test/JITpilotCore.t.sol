// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {JITpilot} from "../src/JITpilot.sol";

/**
 * @title JITpilotCore Tests
 * @dev Focused tests on core JITpilot functionality without complex mocking
 */
contract JITpilotCoreTest is Test {
    JITpilot public jitpilot;

    address public constant LP_ADDRESS = address(0x1234);
    address public constant AUTHORIZED_CALLER = address(0x5678);
    address public constant NON_AUTHORIZED = address(0x9ABC);

    uint256 public constant HF_MIN = 11e17; // 1.1
    uint256 public constant HF_DESIRED = 15e17; // 1.5

    event LPConfigured(address indexed lp, uint256 hfMin, uint256 hfDesired);

    function setUp() public {
        jitpilot = new JITpilot();
        jitpilot.addAuthorizedCaller(AUTHORIZED_CALLER);
    }

    function test_DeploymentState() public {
        // Test initial deployment state
        assertEq(jitpilot.admin(), address(this));
        assertEq(jitpilot.owner(), address(this));
        assertTrue(jitpilot.authorizedCallers(address(this)));
        assertEq(jitpilot.weightHF(), 6e17); // 0.6
        assertEq(jitpilot.weightYield(), 4e17); // 0.4

        // Test that weights sum to 1
        assertEq(jitpilot.weightHF() + jitpilot.weightYield(), 1e18);
    }

    function test_AddressManagement() public {
        address mockEVC = address(0x1111);
        address mockEVK = address(0x2222);
        address mockLens = address(0x3333);
        address mockFactory = address(0x4444);
        address mockImpl = address(0x5555);

        // Test setting addresses as owner
        jitpilot.setEVC(mockEVC);
        jitpilot.setEVK(mockEVK);
        jitpilot.setMaglevLens(mockLens);
        jitpilot.setEulerSwapFactory(mockFactory);
        jitpilot.setEulerSwapImpl(mockImpl);

        // Verify addresses were set
        assertEq(jitpilot.evcAddress(), mockEVC);
        assertEq(jitpilot.evkAddress(), mockEVK);
        assertEq(jitpilot.maglevLensAddress(), mockLens);
        assertEq(jitpilot.eulerSwapFactoryAddress(), mockFactory);
        assertEq(jitpilot.eulerSwapImplAddress(), mockImpl);
    }

    function test_OnlyOwnerModifier() public {
        vm.startPrank(NON_AUTHORIZED);

        vm.expectRevert("Not owner");
        jitpilot.setEVC(address(0x1111));

        vm.expectRevert("Not owner");
        jitpilot.setEVK(address(0x2222));

        vm.expectRevert("Not owner");
        jitpilot.setMaglevLens(address(0x3333));

        vm.expectRevert("Not owner");
        jitpilot.setEulerSwapFactory(address(0x4444));

        vm.expectRevert("Not owner");
        jitpilot.setEulerSwapImpl(address(0x5555));

        vm.stopPrank();
    }

    function test_AuthorizedCallersManagement() public {
        // Initially, only deployer and added caller should be authorized
        assertTrue(jitpilot.authorizedCallers(address(this)));
        assertTrue(jitpilot.authorizedCallers(AUTHORIZED_CALLER));
        assertFalse(jitpilot.authorizedCallers(NON_AUTHORIZED));

        // Add new authorized caller
        vm.prank(AUTHORIZED_CALLER);
        jitpilot.addAuthorizedCaller(NON_AUTHORIZED);
        assertTrue(jitpilot.authorizedCallers(NON_AUTHORIZED));

        // Remove authorized caller
        vm.prank(AUTHORIZED_CALLER);
        jitpilot.removeAuthorizedCaller(NON_AUTHORIZED);
        assertFalse(jitpilot.authorizedCallers(NON_AUTHORIZED));
    }

    function test_UnauthorizedCallersRejected() public {
        vm.startPrank(NON_AUTHORIZED);

        vm.expectRevert("Not authorized");
        jitpilot.addAuthorizedCaller(address(0x7777));

        vm.expectRevert("Not authorized");
        jitpilot.removeAuthorizedCaller(AUTHORIZED_CALLER);

        vm.expectRevert("Not authorized");
        jitpilot.updateWeights(5e17, 5e17);

        vm.stopPrank();
    }

    function test_WeightManagement() public {
        // Test valid weight combinations
        uint256[][] memory validWeights = new uint256[][](4);
        validWeights[0] = new uint256[](2);
        validWeights[0][0] = 1e18; // 100% HF
        validWeights[0][1] = 0; // 0% yield

        validWeights[1] = new uint256[](2);
        validWeights[1][0] = 5e17; // 50% HF
        validWeights[1][1] = 5e17; // 50% yield

        validWeights[2] = new uint256[](2);
        validWeights[2][0] = 3e17; // 30% HF
        validWeights[2][1] = 7e17; // 70% yield

        validWeights[3] = new uint256[](2);
        validWeights[3][0] = 0; // 0% HF
        validWeights[3][1] = 1e18; // 100% yield

        vm.startPrank(AUTHORIZED_CALLER);

        for (uint256 i = 0; i < validWeights.length; i++) {
            uint256 weightHF = validWeights[i][0];
            uint256 weightYield = validWeights[i][1];

            jitpilot.updateWeights(weightHF, weightYield);

            assertEq(jitpilot.weightHF(), weightHF);
            assertEq(jitpilot.weightYield(), weightYield);
            assertEq(jitpilot.weightHF() + jitpilot.weightYield(), 1e18);
        }

        vm.stopPrank();
    }

    function test_InvalidWeights() public {
        vm.startPrank(AUTHORIZED_CALLER);

        // Test weights that don't sum to 1e18
        vm.expectRevert("Weights must sum to 1");
        jitpilot.updateWeights(5e17, 6e17); // Sum = 1.1e18

        vm.expectRevert("Weights must sum to 1");
        jitpilot.updateWeights(3e17, 5e17); // Sum = 0.8e18

        vm.expectRevert("Weights must sum to 1");
        jitpilot.updateWeights(1e18, 1e18); // Sum = 2e18

        vm.expectRevert("Weights must sum to 1");
        jitpilot.updateWeights(1, 1); // Sum = 2 (much less than 1e18)

        vm.stopPrank();
    }

    function test_LPConfiguration() public {
        // Test successful LP configuration
        vm.expectEmit(true, false, false, true);
        emit LPConfigured(LP_ADDRESS, HF_MIN, HF_DESIRED);

        jitpilot.configureLp(LP_ADDRESS, HF_MIN, HF_DESIRED);

        // Verify LP data
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
        assertEq(twaHF, 0); // Initially zero
        assertEq(twaYield, 0); // Initially zero
        assertEq(yieldTarget, 0); // Not implemented yet
        assertEq(lastUpdateBlock, 0); // Not updated yet
    }

    function test_LPConfigurationValidation() public {
        // Test invalid LP address
        vm.expectRevert("Invalid LP address");
        jitpilot.configureLp(address(0), HF_MIN, HF_DESIRED);

        // Test invalid HF range (desired <= min)
        vm.expectRevert("HF desired must be > HF min");
        jitpilot.configureLp(LP_ADDRESS, HF_DESIRED, HF_MIN);

        vm.expectRevert("HF desired must be > HF min");
        jitpilot.configureLp(LP_ADDRESS, HF_DESIRED, HF_DESIRED);
    }

    function test_MultipleLPConfiguration() public {
        address lp1 = address(0x1111);
        address lp2 = address(0x2222);
        address lp3 = address(0x3333);

        // Configure multiple LPs with different parameters
        jitpilot.configureLp(lp1, 11e17, 15e17);
        jitpilot.configureLp(lp2, 12e17, 16e17);
        jitpilot.configureLp(lp3, 105e16, 14e17);

        // Verify each LP has correct configuration
        (,, uint256 hfMin1, uint256 hfDesired1,,,,,,, bool init1,) = jitpilot.getLPData(lp1);
        (,, uint256 hfMin2, uint256 hfDesired2,,,,,,, bool init2,) = jitpilot.getLPData(lp2);
        (,, uint256 hfMin3, uint256 hfDesired3,,,,,,, bool init3,) = jitpilot.getLPData(lp3);

        assertTrue(init1);
        assertTrue(init2);
        assertTrue(init3);

        assertEq(hfMin1, 11e17);
        assertEq(hfDesired1, 15e17);
        assertEq(hfMin2, 12e17);
        assertEq(hfDesired2, 16e17);
        assertEq(hfMin3, 105e16);
        assertEq(hfDesired3, 14e17);
    }

    function test_UpdateMetricsNotConfigured() public {
        // Test updating metrics for non-configured LP
        vm.expectRevert("LP not configured");
        jitpilot.updateMetrics(LP_ADDRESS);
    }

    function testFuzz_ValidWeights(uint256 weightHF) public {
        // Bound weightHF to valid range [0, 1e18]
        weightHF = bound(weightHF, 0, 1e18);
        uint256 weightYield = 1e18 - weightHF;

        vm.prank(AUTHORIZED_CALLER);
        jitpilot.updateWeights(weightHF, weightYield);

        assertEq(jitpilot.weightHF(), weightHF);
        assertEq(jitpilot.weightYield(), weightYield);
        assertEq(jitpilot.weightHF() + jitpilot.weightYield(), 1e18);
    }

    function testFuzz_LPConfiguration(address lpAddress, uint256 hfMin, uint256 hfDesired) public {
        // Skip zero address
        vm.assume(lpAddress != address(0));

        // Bound values to reasonable ranges
        hfMin = bound(hfMin, 1e18, 10e18); // 1.0 to 10.0
        hfDesired = bound(hfDesired, hfMin + 1, 20e18); // Must be > hfMin, up to 20.0

        vm.expectEmit(true, false, false, true);
        emit LPConfigured(lpAddress, hfMin, hfDesired);

        jitpilot.configureLp(lpAddress, hfMin, hfDesired);

        // Verify configuration
        (,, uint256 storedHfMin, uint256 storedHfDesired,,,,,,, bool initialized,) = jitpilot.getLPData(lpAddress);

        assertTrue(initialized);
        assertEq(storedHfMin, hfMin);
        assertEq(storedHfDesired, hfDesired);
    }
}
