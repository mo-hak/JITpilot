// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {DeployScenario} from "../DeployScenario.s.sol";
import {JITpilot} from "../../src/JITpilot.sol";
import {IEulerSwap} from "euler-swap/interfaces/IEulerSwap.sol";
import {HookMiner} from "../../libflat/euler-swap/test/utils/HookMiner.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {MetaProxyDeployer} from "euler-swap/utils/MetaProxyDeployer.sol";
import {TestERC20} from "evk-test/unit/evault/EVaultTestBase.t.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

import {console2 as console} from "forge-std/console2.sol";

contract EulerSwapDebtScenario is DeployScenario {
    address eulerSwap;
    JITpilot jitPilot;

    function setup() internal virtual override {
        vm.startBroadcast(user3PK);
        eUSDC.setLTV(address(eWETH), 0.65e4, 0.67e4, 0);
        eUSDC.setLTV(address(eUSDT), 0.85e4, 0.87e4, 0);
        deployJITpilot();
        vm.stopBroadcast();

        vm.startBroadcast(user2PK);
        createEulerSwap();
        authorizeJITpilot(user2);
        jitPilot.configureLp(user2, 1.4e18, 1.5e18);
        vm.stopBroadcast();

        // create borrow positions for other users
        giveTonsOfCash(user0);
        giveTonsOfCash(user1);
        // giveTonsOfCash(user3);

        depositCollateralIntoVault(user0, user0PK, address(eUSDC), 3_000_000_000e6);
        depositCollateralIntoVault(user1, user1PK, address(eWETH), 1_000_000e18);

        borrowFromVault(user0, user0PK, address(eWETH), 500_000e18);
        borrowFromVault(user1, user1PK, address(eUSDC), 1_600_000_000e6);

        console.log("user2 vault deposits: ", eWETH.balanceOf(user2));
        console.log("user2 vault deposits: ", eUSDC.balanceOf(user2));

        // buy USDC so that user2's EulerSwap position has to borrow USDC
        uint256 amountOut = 286_500_000e6;
        uint256 amountIn = _swapExactOut(address(assetWETH), address(assetUSDC), amountOut, user0, user0PK);
        console.log("SOLD %s WETH FOR %s USDC", amountIn, amountOut);

        // user2 is in debt now. Let's fetch that data
        JITpilot.BlockData memory blockData = jitPilot.getData(user2);

        console.log("==========================================================");
        console.log("EulerSwap instance is in debt now:");
        console.log("allowedLTV:      ", blockData.allowedLTV);
        console.log("currentLTV:      ", blockData.currentLTV);
        console.log("swapFees:        ", blockData.swapFees);
        console.log("netInterest:     ", blockData.netInterest);
        console.log("depositValue:    ", blockData.depositValue);
        console.log("controllerVault: ", blockData.controllerVault);
        console.log("==========================================================");

        // Get a quote for the current price of ETH in the EulerSwap instance
        uint256 ethPrice = eulerSwapPeriphery.quoteExactOutput(eulerSwap, address(assetUSDC), address(assetWETH), 1e18);
        console.log("New price of ETH: ", ethPrice);

        // ETH price has dropped to ~2510. Let's update the oracle
        vm.prank(user3);
        oracle.setPrice(address(eWETH), unitOfAccount, ethPrice * 1e18 / 1e6);

        // Let's see what the rebalancing params would be
        IEulerSwap.Params memory newParams = jitPilot.getRebalancingParams(user2);
        printEulerSwapParams(newParams);
    }

    function giveTonsOfCash(address user) internal virtual {
        assetUSDC.mint(user, 100_000_000_000e6);
        assetUSDT.mint(user, 100_000_000_000e6);
        assetWETH.mint(user, 10_000_000e18);
        assetwstETH.mint(user, 10_000_000e18);
        assetDAI.mint(user, 1_000_000_000e18);
        assetUSDZ.mint(user, 1_000_000_000e18);
    }

    function deployJITpilot() internal {
        jitPilot = new JITpilot();
        jitPilot.setEVC(address(evc));
        // jitPilot.setEVK(address(factory));
        jitPilot.setMaglevLens(address(maglevLens));
        jitPilot.setEulerSwapFactory(address(eulerSwapFactory));

        string memory result = vm.serializeAddress("jitpilot", "jitPilot", address(jitPilot));
        vm.writeJson(result, "./dev-ctx/addresses/31337/JITpilotAddresses.json");
    }

    function authorizeJITpilot(address user) internal {
        evc.setAccountOperator(user, address(jitPilot), true);
    }

    function createEulerSwap() internal {
        // Create pool parameters
        IEulerSwap.Params memory poolParams = IEulerSwap.Params({
            vault0: address(eUSDC),
            vault1: address(eWETH),
            eulerAccount: user2,
            equilibriumReserve0: 800_000_000e6,
            equilibriumReserve1: 280_000e18,
            priceX: 1e18,
            priceY: 2865e6,
            concentrationX: 0.9e18,
            concentrationY: 0.9e18,
            fee: 0,
            protocolFee: 0,
            protocolFeeRecipient: address(0)
        });

        console.log("INITIAL EULERSWAP PARAMS");
        printEulerSwapParams(poolParams);

        // Define required hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        // Mine salt
        bytes memory creationCode = MetaProxyDeployer.creationCodeMetaProxy(eulerSwapImpl, abi.encode(poolParams));
        (address hookAddress, bytes32 salt) = HookMiner.find(address(eulerSwapFactory), flags, creationCode);

        eulerSwap = hookAddress;
        evc.setAccountOperator(user2, eulerSwap, true);

        eulerSwapFactory.deployPool(
            poolParams, IEulerSwap.InitialState({currReserve0: 800_000_000e6, currReserve1: 280_000e18}), salt
        );

        string memory result = vm.serializeAddress("eulerSwap", "eulerSwap", address(eulerSwap));
        vm.writeJson(result, "./dev-ctx/addresses/31337/EulerSwapAddresses.json");
    }

    function depositCollateralIntoVault(address user, uint256 userPK, address vaultAddress, uint256 amount) internal {
        vm.startBroadcast(userPK);
        TestERC20(IEVault(vaultAddress).asset()).mint(user, amount);
        TestERC20(IEVault(vaultAddress).asset()).approve(vaultAddress, type(uint256).max);
        IEVault(vaultAddress).deposit(amount, user);

        if (!evc.isCollateralEnabled(user, vaultAddress)) {
            evc.enableCollateral(user, vaultAddress);
        }

        vm.stopBroadcast();
    }

    function borrowFromVault(address user, uint256 userPK, address vaultAddress, uint256 amount) internal {
        vm.startBroadcast(userPK);

        if (evc.getControllers(user).length > 0) {
            require(evc.isControllerEnabled(user, vaultAddress), "Controller not enabled");
        } else {
            evc.enableController(user, vaultAddress);
        }

        IEVault(vaultAddress).borrow(amount, user);

        vm.stopBroadcast();
    }

    function _swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, address receiver, uint256 userPK)
        internal
        returns (uint256 amountIn)
    {
        vm.startBroadcast(userPK);
        amountIn = eulerSwapPeriphery.quoteExactOutput(eulerSwap, tokenIn, tokenOut, amountOut);
        console.log("amountIn", amountIn);

        TestERC20(tokenIn).approve(address(eulerSwapPeriphery), type(uint256).max);
        eulerSwapPeriphery.swapExactOut(
            eulerSwap,
            tokenIn,
            tokenOut,
            amountOut,
            receiver,
            amountIn * 101 / 100, // allow up to 1% slippage
            0
        );
        vm.stopBroadcast();

        return amountIn;
    }

    function printEulerSwapParams(IEulerSwap.Params memory params) internal {
        console.log("==========================================================");
        console.log("vault0:               ", params.vault0);
        console.log("vault1:               ", params.vault1);
        console.log("eulerAccount:         ", params.eulerAccount);
        console.log("equilibriumReserve0:  ", params.equilibriumReserve0);
        console.log("equilibriumReserve1:  ", params.equilibriumReserve1);
        console.log("priceX:               ", params.priceX);
        console.log("priceY:               ", params.priceY);
        console.log("concentrationX:       ", params.concentrationX);
        console.log("concentrationY:       ", params.concentrationY);
        console.log("fee:                  ", params.fee);
        console.log("protocolFee:          ", params.protocolFee);
        console.log("protocolFeeRecipient: ", params.protocolFeeRecipient);
        console.log("==========================================================");
    }
}
