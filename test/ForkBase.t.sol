// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IB20} from "base-std/interfaces/IB20.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {LiqpadFactory} from "../src/LiqpadFactory.sol";
import {IVeniceStaking} from "../src/interfaces/IVeniceStaking.sol";
import {IDiemMinter} from "../src/interfaces/IDiemMinter.sol";
import {DeploySepolia} from "../script/DeploySepolia.s.sol";

/// @notice Live precompile test. Run with Base Foundry and a Base fork URL; see the Ubuntu runbook.
contract ForkBaseTest is Test {
    address internal constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant BASE_VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address internal constant BASE_SVVV = 0x321b7ff75154472B18EDb199033fF4D116F340Ff;
    address internal constant BASE_DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    function testForkVerifiedVeniceReadSignatures() external view {
        if (!vm.envOr("LIVE_VENICE", false)) return;
        assertEq(block.chainid, 8453, "Base mainnet fork required");
        assertGt(BASE_SVVV.code.length, 0);
        assertGt(BASE_DIEM.code.length, 0);
        assertEq(IVeniceStaking(BASE_SVVV).cooldownDuration(), 7 days);
        assertEq(IDiemMinter(BASE_DIEM).cooldownDuration(), 1 days);
        assertGt(IVeniceStaking(BASE_SVVV).getDiemAmountOut(1e18), 0);
        assertEq(IVeniceStaking(BASE_SVVV).balanceOfUnlocked(address(this)), 0);
    }

    function testForkSepoliaMocksAndDeploymentFailClosedOnBase() external {
        if (!vm.envOr("LIVE_SECURITY", false)) return;
        assertEq(block.chainid, 8453, "Base mainnet fork required");
        DeploySepolia deployScript = new DeploySepolia();
        vm.expectRevert(bytes("BASE_SEPOLIA_ONLY"));
        deployScript.run();
    }

    function testForkPinsLiveBaseV4AndVVV() external view {
        if (!vm.envOr("LIVE_V4", false)) return;
        assertEq(block.chainid, 8453, "Base mainnet fork required");
        assertGt(BASE_POOL_MANAGER.code.length, 0, "PoolManager missing");
        assertGt(BASE_VVV.code.length, 0, "VVV missing");
    }

    function testForkCreatesNativeB20AndRemovesPrivileges() external {
        if (!vm.envOr("LIVE_B20", false)) return;
        assertTrue(block.chainid == 8453 || block.chainid == 84532, "Base fork required");

        LiqpadFactory factory = new LiqpadFactory();
        address creator = makeAddr("forkCreator");
        bytes32 salt = keccak256(abi.encode("liqpad-phase-2", address(factory), block.number));
        LiqpadFactory.LaunchParams memory params = LiqpadFactory.LaunchParams({
            name: "Liqpad Fork Demo",
            symbol: "LQFORK",
            salt: salt,
            contractURI: "ipfs://liqpad-phase-2-contract-uri",
            description: "Native B20 created by Liqpad on a Base fork.",
            logoURI: "ipfs://liqpad-phase-2-logo",
            website: "https://liqpad.example",
            socials: LiqpadFactory.Socials({twitter: "https://x.com/liqpad", telegram: "", farcaster: "", discord: ""}),
            creator: creator
        });

        address predicted = factory.predictAddress(salt);
        vm.prank(creator);
        address token = factory.createLaunch(params);
        IB20 b20 = IB20(token);

        assertEq(token, predicted);
        assertEq(b20.name(), params.name);
        assertEq(b20.symbol(), params.symbol);
        assertEq(b20.decimals(), 18);
        assertEq(b20.totalSupply(), factory.TOKEN_SUPPLY());
        assertEq(b20.supplyCap(), factory.TOKEN_SUPPLY());
        assertEq(b20.balanceOf(address(factory)), factory.TOKEN_SUPPLY());
        assertEq(b20.contractURI(), params.contractURI);

        LiqpadFactory.Profile memory profile = factory.getProfile(token);
        assertEq(profile.creator, creator);
        assertEq(profile.description, params.description);
        assertEq(profile.logoURI, params.logoURI);
        assertEq(profile.website, params.website);
        assertEq(profile.socials.twitter, params.socials.twitter);

        bytes32[8] memory roles = [
            bytes32(0),
            B20Constants.MINT_ROLE,
            B20Constants.BURN_ROLE,
            B20Constants.BURN_BLOCKED_ROLE,
            B20Constants.PAUSE_ROLE,
            B20Constants.UNPAUSE_ROLE,
            B20Constants.METADATA_ROLE,
            B20Constants.OPERATOR_ROLE
        ];
        for (uint256 i; i < roles.length; ++i) {
            assertFalse(b20.hasRole(roles[i], creator));
            assertFalse(b20.hasRole(roles[i], address(factory)));
        }
    }
}
