// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LiqpadLaunchHook} from "./LiqpadLaunchHook.sol";
import {FeeRouter} from "./FeeRouter.sol";

/// @notice Minimal CREATE2 deployer used so hook address mining has an unambiguous deployer.
contract HookDeployer {
    function deploy(bytes32 salt, IPoolManager manager, address vvv, address factory, FeeRouter router)
        external
        returns (LiqpadLaunchHook hook)
    {
        hook = new LiqpadLaunchHook{salt: salt}(manager, vvv, factory, router);
    }
}
