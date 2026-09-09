// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LiqpadFactory} from "../src/LiqpadFactory.sol";
import {MockB20Factory} from "./mocks/MockB20Factory.sol";
import {TestableLiqpadFactory} from "./mocks/TestableLiqpadFactory.sol";

contract QuoteAuthorizationTest is Test {
    uint256 private constant SIGNER_KEY = 0xA11CE;
    uint256 private constant NEW_SIGNER_KEY = 0xB0B;

    TestableLiqpadFactory private factory;
    address private creator = makeAddr("quoteCreator");

    function setUp() external {
        factory = new TestableLiqpadFactory(new MockB20Factory(), address(this), vm.addr(SIGNER_KEY));
    }

    function testValidEip712QuoteCreatesLaunch() external {
        LiqpadFactory.LaunchParams memory p = _params(keccak256("valid"));
        LiqpadFactory.LaunchQuote memory quote = _quote(p);
        address predicted = factory.predictAddress(p.salt);
        vm.prank(creator);
        assertEq(factory.createLaunch(p, quote, _sign(quote, SIGNER_KEY)), predicted);
    }

    function testExpiredQuoteReverts() external {
        LiqpadFactory.LaunchParams memory p = _params(keccak256("expired"));
        LiqpadFactory.LaunchQuote memory quote = _quote(p);
        quote.validUntil = uint64(block.timestamp - 1);
        bytes memory signature = _sign(quote, SIGNER_KEY);
        vm.expectRevert(LiqpadFactory.QuoteExpired.selector);
        factory.createLaunch(p, quote, signature);
    }

    function testQuoteIsBoundToCreatorAndSalt() external {
        LiqpadFactory.LaunchParams memory p = _params(keccak256("binding"));
        LiqpadFactory.LaunchQuote memory quote = _quote(p);
        quote.creator = address(0xBAD);
        bytes memory signature = _sign(quote, SIGNER_KEY);
        vm.expectRevert(LiqpadFactory.InvalidQuoteCreator.selector);
        factory.createLaunch(p, quote, signature);

        quote = _quote(p);
        quote.launchSalt = keccak256("other-salt");
        signature = _sign(quote, SIGNER_KEY);
        vm.expectRevert(LiqpadFactory.InvalidQuoteSalt.selector);
        factory.createLaunch(p, quote, signature);
    }

    function testRejectsUnalignedOutOfBoundsAndWrongSigner() external {
        LiqpadFactory.LaunchParams memory p = _params(keccak256("invalid-frame"));
        LiqpadFactory.LaunchQuote memory quote = _quote(p);
        quote.quotedFrame = 144_801;
        bytes memory signature = _sign(quote, SIGNER_KEY);
        vm.expectRevert(LiqpadFactory.InvalidQuotedFrame.selector);
        factory.createLaunch(p, quote, signature);

        quote = _quote(p);
        quote.quotedFrame = 79_800;
        signature = _sign(quote, SIGNER_KEY);
        vm.expectRevert(LiqpadFactory.InvalidQuotedFrame.selector);
        factory.createLaunch(p, quote, signature);

        quote = _quote(p);
        signature = _sign(quote, NEW_SIGNER_KEY);
        vm.expectRevert(LiqpadFactory.InvalidQuoteSignature.selector);
        factory.createLaunch(p, quote, signature);
    }

    function testQuoteAdminCanRotateSigner() external {
        factory.setQuoteSigner(vm.addr(NEW_SIGNER_KEY));
        assertEq(factory.quoteSigner(), vm.addr(NEW_SIGNER_KEY));

        LiqpadFactory.LaunchParams memory p = _params(keccak256("rotated"));
        LiqpadFactory.LaunchQuote memory quote = _quote(p);
        assertEq(factory.createLaunch(p, quote, _sign(quote, NEW_SIGNER_KEY)), factory.predictAddress(p.salt));
    }

    function testNonAdminCannotRotateSigner() external {
        vm.prank(address(0xBAD));
        vm.expectRevert(LiqpadFactory.OnlyQuoteAdmin.selector);
        factory.setQuoteSigner(vm.addr(NEW_SIGNER_KEY));
    }

    function _params(bytes32 salt) private view returns (LiqpadFactory.LaunchParams memory) {
        return LiqpadFactory.LaunchParams({
            name: "Signed Launch",
            symbol: "SIGNED",
            salt: salt,
            contractURI: "ipfs://signed",
            description: "offline signed quote test",
            logoURI: "",
            website: "",
            socials: LiqpadFactory.Socials("", "", "", ""),
            creator: creator
        });
    }

    function _quote(LiqpadFactory.LaunchParams memory p)
        private
        view
        returns (LiqpadFactory.LaunchQuote memory)
    {
        return LiqpadFactory.LaunchQuote({
            quotedFrame: 144_800,
            validUntil: uint64(block.timestamp + 10 minutes),
            creator: p.creator,
            launchSalt: p.salt
        });
    }

    function _sign(LiqpadFactory.LaunchQuote memory quote, uint256 key) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, factory.hashLaunchQuote(quote));
        return abi.encodePacked(r, s, v);
    }
}
