// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {LiqpadFactory} from "../src/LiqpadFactory.sol";
import {MockB20} from "./mocks/MockB20.sol";
import {MockB20Factory} from "./mocks/MockB20Factory.sol";
import {TestableLiqpadFactory} from "./mocks/TestableLiqpadFactory.sol";

contract LaunchTest is Test {
    event Launch(address indexed token, address indexed creator, bytes32 indexed poolId, bytes32 profileHash);

    MockB20Factory internal b20Factory;
    TestableLiqpadFactory internal factory;
    address internal creator = makeAddr("creator");

    function setUp() external {
        b20Factory = new MockB20Factory();
        factory = new TestableLiqpadFactory(b20Factory);
    }

    function testCreateLaunchMintsFixedSupplyAndStoresProfile() external {
        LiqpadFactory.LaunchParams memory params = _params();
        address predicted = factory.predictAddress(params.salt);

        vm.expectEmit(true, true, true, false, address(factory));
        emit Launch(predicted, creator, bytes32(0), bytes32(0));
        vm.prank(creator);
        address token = factory.createLaunch(params);

        assertEq(token, predicted);
        assertEq(MockB20(token).name(), params.name);
        assertEq(MockB20(token).symbol(), params.symbol);
        assertEq(MockB20(token).decimals(), 18);
        assertEq(MockB20(token).totalSupply(), factory.TOKEN_SUPPLY());
        assertEq(MockB20(token).supplyCap(), factory.TOKEN_SUPPLY());
        assertEq(MockB20(token).balanceOf(address(factory)), factory.TOKEN_SUPPLY());
        assertEq(MockB20(token).contractURI(), params.contractURI);

        LiqpadFactory.Profile memory profile = factory.getProfile(token);
        assertEq(profile.creator, creator);
        assertEq(profile.name, params.name);
        assertEq(profile.symbol, params.symbol);
        assertEq(profile.description, params.description);
        assertEq(profile.logoURI, params.logoURI);
        assertEq(profile.website, params.website);
        assertEq(profile.contractURI, params.contractURI);
        assertEq(profile.socials.twitter, params.socials.twitter);
        assertEq(profile.socials.telegram, params.socials.telegram);
        assertEq(profile.socials.farcaster, params.socials.farcaster);
        assertEq(profile.socials.discord, params.socials.discord);
        assertEq(profile.poolId, bytes32(0));
        assertTrue(factory.isLiqpadLaunch(token));
        assertEq(factory.creatorTokens(creator)[0], token);
    }

    function testLaunchLeavesCreatorAndFactoryWithoutPrivilegedRoles() external {
        LiqpadFactory.LaunchParams memory params = _params();
        vm.prank(creator);
        MockB20 token = MockB20(factory.createLaunch(params));

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
            assertFalse(token.hasRole(roles[i], creator));
            assertFalse(token.hasRole(roles[i], address(factory)));
        }
    }

    function testZeroCreatorDefaultsToCaller() external {
        LiqpadFactory.LaunchParams memory params = _params();
        params.creator = address(0);
        vm.prank(creator);
        address token = factory.createLaunch(params);
        assertEq(factory.getProfile(token).creator, creator);
    }

    function testRejectsEmptyRequiredMetadata() external {
        LiqpadFactory.LaunchParams memory params = _params();
        params.contractURI = "";
        vm.expectRevert(LiqpadFactory.EmptyContractURI.selector);
        factory.createLaunch(params);
    }

    function _params() private view returns (LiqpadFactory.LaunchParams memory) {
        return LiqpadFactory.LaunchParams({
            name: "Liqpad Demo",
            symbol: "LIQDEMO",
            salt: keccak256("phase-2-unit-salt"),
            contractURI: "ipfs://bafy-contract-metadata",
            description: "A Phase 2 native B20 launch test.",
            logoURI: "ipfs://bafy-logo",
            website: "https://liqpad.example",
            socials: LiqpadFactory.Socials({
                twitter: "https://x.com/liqpad",
                telegram: "https://t.me/liqpad",
                farcaster: "https://farcaster.xyz/liqpad",
                discord: "https://discord.gg/liqpad"
            }),
            creator: creator
        });
    }
}
