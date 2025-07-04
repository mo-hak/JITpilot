// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {DeployScenario} from "../DeployScenario.s.sol";
import {JITpilot} from "../../src/JITpilot.sol";
import {IEulerSwap} from "euler-swap/interfaces/IEulerSwap.sol";
import {HookMiner} from "../../libflat/euler-swap/test/utils/HookMiner.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {MetaProxyDeployer} from "euler-swap/utils/MetaProxyDeployer.sol";
import {console2 as console} from "forge-std/console2.sol";
import {TestERC20} from "evk-test/unit/evault/EVaultTestBase.t.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

contract EulerSwapDebtScenario is DeployScenario {

    address eulerSwap;
    JITpilot jitPilot;

    function setup() internal virtual override {
        vm.startBroadcast(user3PK);
        eUSDC.setLTV(address(eWETH), 0.65e4, 0.67e4, 0);
        eUSDC.setLTV(address(eUSDT), 0.85e4, 0.87e4, 0);
        deployJITPilot();
        vm.stopBroadcast();

        createEulerSwap(); // user 2

        // create borrow positions for other users
        giveTonsOfCash(user0);
        giveTonsOfCash(user1);
        // giveTonsOfCash(user3);

        depositCollateralIntoVault(user0, user0PK, address(eUSDC), 3_000_000_000e6);
        depositCollateralIntoVault(user1, user1PK, address(eWETH), 1_000_000e18);

        borrowFromVault(user0, user0PK, address(eWETH), 500_000e18);
        borrowFromVault(user1, user1PK, address(eUSDC), 1_600_000_000e6);

        jitPilot.getData(user2);
        console.log("user2", user2);
        
        // buy USDC so that user2's EulerSwap position has to borrow
        uint256 amountOut = 286_500_000e6;
        _swapExactOut(address(assetWETH), address(assetUSDC), amountOut, user0, user0PK);
    }

    function giveTonsOfCash(address user) internal virtual {
        assetUSDC.mint(user, 100_000_000_000e6);
        assetUSDT.mint(user, 100_000_000_000e6);
        assetWETH.mint(user, 10_000_000e18);
        assetwstETH.mint(user, 10_000_000e18);
        assetDAI.mint(user, 1_000_000_000e18);
        assetUSDZ.mint(user, 1_000_000_000e18);
    }

    function deployJITPilot() internal {
        jitPilot = new JITpilot();
        jitPilot.setEVC(address(evc));
        // jitPilot.setEVK(address(factory));
        jitPilot.setMaglevLens(address(maglevLens));
        jitPilot.setEulerSwapFactory(address(eulerSwapFactory));

        string memory result = vm.serializeAddress("jitpilot", "jitPilot", address(jitPilot));
        vm.writeJson(result, "./dev-ctx/addresses/31337/JITpilotAddresses.json");
    }

    function createEulerSwap() internal {
        vm.startBroadcast(user2PK);
        
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

        // Define required hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.BEFORE_DONATE_FLAG | 
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        
        // Mine salt
        bytes memory creationCode = MetaProxyDeployer.creationCodeMetaProxy(eulerSwapImpl, abi.encode(poolParams));
        (address hookAddress, bytes32 salt) = HookMiner.find(address(eulerSwapFactory), flags, creationCode);
        
        eulerSwap = hookAddress;
        evc.setAccountOperator(user2, eulerSwap, true);

        eulerSwapFactory.deployPool(poolParams, IEulerSwap.InitialState({
            currReserve0: 800_000_000e6,
            currReserve1: 280_000e18
        }), salt);

        string memory result = vm.serializeAddress("eulerSwap", "eulerSwap", address(eulerSwap));
        vm.writeJson(result, "./dev-ctx/addresses/31337/EulerSwapAddresses.json");
        vm.stopBroadcast();
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

    function _swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, address receiver, uint256 userPK) internal {
        vm.startBroadcast(userPK);
        uint256 amountIn = eulerSwapPeriphery.quoteExactOutput(
            eulerSwap,
            tokenIn,
            tokenOut,
            amountOut
        );
        console.log("amountIn", amountIn);

        TestERC20(tokenIn).approve(address(eulerSwapPeriphery), type(uint256).max);
        console.log("user1's WETH balance (tokenIn)", TestERC20(tokenIn).balanceOf(user1));
        console.log("WETH address (tokenIn)", tokenIn);
        console.log("user1's USDC balance (tokenOut)", TestERC20(tokenOut).balanceOf(user1));
        console.log("USDC address (tokenOut)", tokenOut);
        console.log("user1's address: ", user1);
        console.log("eulerSwap address: ", eulerSwap);
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
    }
}