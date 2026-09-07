// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LiqpadFactory, ILiqpadLaunchHook, IFeeRouterBinding, ILiqpadLiquidityLocker} from "../src/LiqpadFactory.sol";
import {LiqpadLaunchHook} from "../src/LiqpadLaunchHook.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {DiemEngine} from "../src/DiemEngine.sol";
import {VeniceAdapter} from "../src/adapters/VeniceAdapter.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {LockedPositionVault} from "../src/LockedPositionVault.sol";

/// @notice Base Factory v2 deployment that reuses the live VeniceAdapter and DiemEngine.
contract DeployBase is Script {
    address public constant B20_FACTORY = 0xB20f000000000000000000000000000000000000;
    address public constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address public constant SVVV = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;
    address public constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address public constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address public constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant VENICE_ADAPTER = 0xBEa3A03c4A76fADdBD77458525a4E36eAE64d746;
    address public constant DIEM_ENGINE = 0xd44BbD89d490B079ba546e192eb30CB1836F2958;
    int24 public constant QUOTED_FRAME = 115_200;

    uint160 private constant REQUIRED_FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    uint160 private constant ALL_HOOK_MASK = (1 << 14) - 1;

    struct Deployment {
        LiqpadFactory factory;
        FeeRouter router;
        HookDeployer hookDeployer;
        LiqpadLaunchHook hook;
        LockedPositionVault lockVault;
        bytes32 salt;
    }

    function run() external {
        require(block.chainid == 8_453, "BASE_MAINNET_ONLY");
        bool dryRun = vm.isContext(VmSafe.ForgeContext.ScriptDryRun);
        bool broadcast = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
        require(dryRun || broadcast, "SCRIPT_CONTEXT_REJECTED");

        bool simulationOnly = vm.envBool("MAINNET_SIMULATION_ONLY");
        bool factoryV2Authorized = vm.envBool("MAINNET_FACTORY_V2_BROADCAST_AUTHORIZED");
        if (dryRun) {
            require(simulationOnly, "MAINNET_SIMULATION_REQUIRED");
            require(!factoryV2Authorized, "DRY_RUN_AUTH_FLAG_MUST_BE_FALSE");
        } else {
            require(!simulationOnly, "MAINNET_SIMULATION_ONLY_LOCKED");
            require(factoryV2Authorized, "FACTORY_V2_BROADCAST_NOT_AUTHORIZED");
        }
        _requireLiveCode(VVV, "VVV_NO_CODE");
        _requireLiveCode(SVVV, "SVVV_NO_CODE");
        _requireLiveCode(DIEM, "DIEM_NO_CODE");
        _requireLiveCode(POOL_MANAGER, "POOL_MANAGER_NO_CODE");
        _requireLiveCode(POSITION_MANAGER, "POSITION_MANAGER_NO_CODE");
        _requireLiveCode(PERMIT2, "PERMIT2_NO_CODE");
        _requireLiveCode(VENICE_ADAPTER, "VENICE_ADAPTER_NO_CODE");
        _requireLiveCode(DIEM_ENGINE, "DIEM_ENGINE_NO_CODE");
        _requireExistingVeniceWiring();

        if (broadcast) vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        Deployment memory d = _deploy(vm.envUint("HOOK_MINE_MAX_ITERATIONS"));
        if (broadcast) vm.stopBroadcast();
        _print(d, broadcast);
    }

    function _deploy(uint256 maxIterations) private returns (Deployment memory d) {
        d.factory = new LiqpadFactory();
        require(d.factory.b20Factory() == B20_FACTORY, "B20_FACTORY_MISMATCH");
        d.router = new FeeRouter(VVV, address(d.factory), DIEM_ENGINE);
        d.hookDeployer = new HookDeployer();
        d.lockVault = new LockedPositionVault(POSITION_MANAGER, PERMIT2, address(d.factory));

        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(LiqpadLaunchHook).creationCode,
                abi.encode(IPoolManager(POOL_MANAGER), VVV, address(d.factory), d.router)
            )
        );
        address expected;
        (d.salt, expected) = _mine(address(d.hookDeployer), initHash, maxIterations);
        d.hook = d.hookDeployer.deploy(d.salt, IPoolManager(POOL_MANAGER), VVV, address(d.factory), d.router);
        require(address(d.hook) == expected, "HOOK_ADDRESS_MISMATCH");
        d.factory
            .configurePhase3(
                IPoolManager(POOL_MANAGER),
                ILiqpadLaunchHook(address(d.hook)),
                VVV,
                IFeeRouterBinding(address(d.router)),
                ILiqpadLiquidityLocker(address(d.lockVault)),
                QUOTED_FRAME
            );
    }

    function _print(Deployment memory d, bool broadcast) private pure {
        console2.log(broadcast ? "FACTORY V2 BROADCAST" : "SIMULATION ONLY");
        console2.log("Factory", address(d.factory));
        console2.log("Hook", address(d.hook));
        console2.log("FeeRouter", address(d.router));
        console2.log("Existing DiemEngine", DIEM_ENGINE);
        console2.log("Existing VeniceAdapter", VENICE_ADAPTER);
        console2.log("HookDeployer", address(d.hookDeployer));
        console2.log("LockedPositionVault", address(d.lockVault));
        console2.log("Quoted frame", int256(QUOTED_FRAME));
        console2.log("Hook salt");
        console2.logBytes32(d.salt);
        console2.log(
            broadcast
                ? "Broadcast artifact: broadcast/DeployBase.s.sol/8453/run-latest.json"
                : "No broadcast artifact is created"
        );
    }

    function _requireExistingVeniceWiring() private view {
        VeniceAdapter adapter = VeniceAdapter(VENICE_ADAPTER);
        DiemEngine engine = DiemEngine(DIEM_ENGINE);
        require(adapter.engine() == DIEM_ENGINE, "ADAPTER_ENGINE_MISMATCH");
        require(address(engine.adapter()) == VENICE_ADAPTER, "ENGINE_ADAPTER_MISMATCH");
        require(adapter.VVV() == VVV && engine.VVV() == VVV, "VENICE_VVV_MISMATCH");
        require(adapter.SVVV() == SVVV, "VENICE_SVVV_MISMATCH");
        require(adapter.DIEM() == DIEM, "VENICE_DIEM_MISMATCH");
    }

    function _requireLiveCode(address target, string memory reason) private view {
        require(target.code.length != 0, reason);
    }

    function _mine(address deployer, bytes32 initHash, uint256 maxIterations)
        private
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < maxIterations; ++i) {
            salt = bytes32(i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(predicted) & ALL_HOOK_MASK == REQUIRED_FLAGS) return (salt, predicted);
        }
        revert("HOOK_SALT_NOT_FOUND_IN_LIMIT");
    }
}
