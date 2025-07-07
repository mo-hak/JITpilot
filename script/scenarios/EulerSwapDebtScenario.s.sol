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
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEulerSwapFactory} from "euler-swap/interfaces/IEulerSwapFactory.sol";
import {CurveLib} from "euler-swap/libraries/CurveLib.sol";

import {console2 as console} from "forge-std/console2.sol";

contract EulerSwapDebtScenario is DeployScenario {
    address eulerSwap;
    JITpilot jitPilot;

    function setup() internal virtual override {
        vm.startBroadcast(user3PK);
        eUSDC.setLTV(address(eWETH), 0.65e4, 0.67e4, 0);
        eUSDC.setLTV(address(eUSDT), 0.85e4, 0.87e4, 0);
        eWETH.setLTV(address(eUSDC), 0.65e4, 0.67e4, 0);
        eWETH.setLTV(address(eUSDT), 0.85e4, 0.87e4, 0);
        eUSDT.setLTV(address(eWETH), 0.85e4, 0.87e4, 0);
        eUSDT.setLTV(address(eUSDC), 0.85e4, 0.87e4, 0);
        deployJITpilot();
        vm.stopBroadcast();

        vm.startBroadcast(user2PK);
        deployEulerSwap(getInitialEulerSwapParams(), false);
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

        // buy USDC so that user2's EulerSwap position has to borrow USDC
        uint256 amountOut = 286_500_000e6;
        uint256 amountIn = _swapExactOut(address(assetWETH), address(assetUSDC), amountOut, user0, user0PK);
        console.log("marketUser SOLD %s WETH FOR %s USDC", amountIn, amountOut);

        // user2 is in debt now. Let's fetch that data
        console.log("EulerSwap state now after servicing trades: ");
        printEulerSwapData(user2);

        // Get a quote for the current price of ETH in the EulerSwap instance
        uint256 ethPrice = eulerSwapPeriphery.quoteExactOutput(eulerSwap, address(assetUSDC), address(assetWETH), 1e18);
        console.log("New price of ETH: ", ethPrice);

        // ETH price has dropped to ~2510. Let's update the oracle
        vm.prank(user3);
        oracle.setPrice(address(eWETH), unitOfAccount, ethPrice * 1e18 / 1e6);

        // Let's see what the rebalancing params would be
        IEulerSwap.Params memory newParams = jitPilot.getRebalancingParams(user2);
        printEulerSwapParams(newParams);

        // let's do the actual rebalancing then
        vm.startBroadcast(user2PK);
        jitPilot.updateMetrics(user2);
        IEVC(evc).setAccountOperator(user2, eulerSwap, false);
        IEulerSwapFactory(eulerSwapFactory).uninstallPool();
        deployEulerSwap(newParams, true);
        vm.stopBroadcast();

        // Now let's see if the rebalancing was successful
        address poolAddr = eulerSwapFactory.poolByEulerAccount(user2);
        newParams = IEulerSwap(poolAddr).getParams();
        printEulerSwapParams(newParams);

        // Let's buy some WETH on the EulerSwap pool and see the effect on the debt
        // sell USDC so that user2's EulerSwap position has to borrow USDC
        uint256 newEthPrice = eulerSwapPeriphery.quoteExactOutput(eulerSwap, address(assetUSDC), address(assetWETH), 1e18);
        console.log("price of ETH (market): ", ethPrice);
        console.log("price of ETH (EulerSwap): ", newEthPrice);
        amountIn = 105_000_000e6;
        amountOut = _swapExactIn(address(assetUSDC), address(assetWETH), amountIn, user0, user0PK);
        console.log("marketUser BOUGHT %s WETH FOR %s USDC (price: %s)", amountOut, amountIn, amountIn * 1e18 / amountOut);

        // Let's see the new state of the EulerSwap pool after arbitrage
        console.log("EulerSwap state now (after arbitrage):");
        printEulerSwapData(user2);
        console.log("price of ETH (EulerSwap, after arbitrage): ", eulerSwapPeriphery.quoteExactOutput(eulerSwap, address(assetUSDC), address(assetWETH), 1e18));
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

    function deployEulerSwap(IEulerSwap.Params memory poolParams, bool rebalancing) internal {

        console.log("DEPLOYING EULERSWAP WITH PARAMS");
        printEulerSwapParams(poolParams);

        bool asset0IsDebt = getCurrentControllerVault(poolParams.eulerAccount) == poolParams.vault0;
        uint112 currentReserve0 = poolParams.equilibriumReserve0;
        uint112 currentReserve1 = poolParams.equilibriumReserve1;

        IEulerSwap.InitialState memory initialState;
        if (!rebalancing) {
            initialState = IEulerSwap.InitialState({currReserve0: poolParams.equilibriumReserve0, currReserve1: poolParams.equilibriumReserve1});
        } else { 
            if (asset0IsDebt) {
                {
                    uint256 deltaReservesAsset0 = poolParams.equilibriumReserve0 * 1/3;
                    // uint256 deltaReservesAsset1 = deltaReservesAsset0 * poolParams.priceX / poolParams.priceY;
                    currentReserve0 = uint112(poolParams.equilibriumReserve0 - deltaReservesAsset0);
                    // currentReserve1 = uint112(poolParams.equilibriumReserve1 + deltaReservesAsset1);
                    currentReserve1 = uint112(CurveLib.f(uint256(currentReserve0), uint256(poolParams.priceX), uint256(poolParams.priceY), uint256(poolParams.equilibriumReserve0), uint256(poolParams.equilibriumReserve1), uint256(poolParams.concentrationX)));
                }
            } else {
                {
                    uint256 deltaReservesAsset1 = poolParams.equilibriumReserve1 * 1/3;
                    // uint256 deltaReservesAsset0 = deltaReservesAsset1 * poolParams.priceY / poolParams.priceX;
                    currentReserve1 = uint112(poolParams.equilibriumReserve1 - deltaReservesAsset1);
                    // currentReserve0 = uint112(poolParams.equilibriumReserve0 + deltaReservesAsset0);
                    currentReserve0 = uint112(CurveLib.fInverse(uint256(currentReserve1), uint256(poolParams.priceY), uint256(poolParams.priceX), uint256(poolParams.equilibriumReserve1), uint256(poolParams.equilibriumReserve0), uint256(poolParams.concentrationY)));
                }
            }
            initialState = IEulerSwap.InitialState({currReserve0: currentReserve0, currReserve1: currentReserve1});
        }

        // Define required hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        // Mine salt
        bytes memory creationCode = MetaProxyDeployer.creationCodeMetaProxy(eulerSwapImpl, abi.encode(poolParams));
        (address hookAddress, bytes32 salt) = HookMiner.find(address(eulerSwapFactory), flags, creationCode);

        eulerSwap = hookAddress;
        // Deploy pool via EVC batch
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            onBehalfOfAccount: address(0),
            targetContract: address(evc),
            value: 0,
            data: abi.encodeCall(evc.setAccountOperator, (user2, eulerSwap, true))
        });
        items[1] = IEVC.BatchItem({
            onBehalfOfAccount: user2,
            targetContract: address(eulerSwapFactory),
            value: 0,
            data: abi.encodeCall(IEulerSwapFactory.deployPool, (poolParams, initialState, salt))
        });
        evc.batch(items);

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
        // console.log("amountIn", amountIn);

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

    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, address receiver, uint256 userPK)
        internal
        returns (uint256 amountOut)
    {
        vm.startBroadcast(userPK);
        amountOut = eulerSwapPeriphery.quoteExactInput(eulerSwap, tokenIn, tokenOut, amountIn);
        // console.log("amountOut", amountOut);

        TestERC20(tokenIn).approve(address(eulerSwapPeriphery), type(uint256).max);
        eulerSwapPeriphery.swapExactIn(
            eulerSwap,
            tokenIn,
            tokenOut,
            amountIn,
            receiver,
            amountOut * 99 / 100, // allow up to 1% slippage
            0
        );
        vm.stopBroadcast();

        return amountOut;
    }

    function getInitialEulerSwapParams() internal view returns (IEulerSwap.Params memory) {
        return IEulerSwap.Params({
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
    }

    function printEulerSwapParams(IEulerSwap.Params memory params) internal pure {
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

    function printEulerSwapData(address user) internal view {

        JITpilot.BlockData memory blockData = jitPilot.getData(user);

        console.log("==========================================================");
        console.log("healthFactor:    ", blockData.allowedLTV * 1e4 / blockData.currentLTV / 100, "%");
        console.log("allowedLTV:      ", blockData.allowedLTV);
        console.log("currentLTV:      ", blockData.currentLTV);
        console.log("swapFees:        ", blockData.swapFees);
        console.log("netInterest:     ", blockData.netInterest);
        console.log("depositValue:    ", blockData.depositValue);
        console.log("controllerVault: ", blockData.controllerVault);
        console.log("==========================================================");
    }
    
    function getCurrentControllerVault(address lp) internal view returns (address) {
        address[] memory controllerVaults = evc.getControllers(lp);
        address currentControllerVault;

        if (controllerVaults.length == 0) return address(0);

        // find which of the LP's controller vaults is the enabled debt vault
        for (uint256 i; i < controllerVaults.length; ++i) {
            if (evc.isControllerEnabled(lp, controllerVaults[i])) {
                currentControllerVault = controllerVaults[i];
                break;
            }
        }
        return currentControllerVault;
    }
}
