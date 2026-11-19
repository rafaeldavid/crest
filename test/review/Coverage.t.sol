// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {IHoldbackModule} from "../../src/modules/holdback/IHoldbackModule.sol";
import {CrestBase} from "../CrestBase.sol";

/// Review of PR 2 (vault-v01). Controls from docs/design.md section 8 that the PR's own tests do not attack. Each
/// test here passes on the PR's code: the control holds, and the PR lacks the test.
contract ReviewCoverageTest is CrestBase {
    uint256 internal subGrant;

    function setUp() public override {
        super.setUp();
        vm.prank(buyer);
        subGrant = vault.grant(agentGrant, sub, _wide(), 0, "");
    }

    // Each limit at an ancestor (the PR tests per-payment, per-period and the list at an ancestor, not these).

    function test_attack_overTheAgentsLifetime_bySubAgent_refused() public {
        _setAgentCaps(_caps(HOLD, type(uint128).max, HOLD, 10, true, true));
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        _expectRefused(
            _vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.OverLifetime.selector, agentGrant)
        );
    }

    function test_attack_overTheAgentsOpenCount_bySubAgent_refused() public {
        _setAgentCaps(_caps(HOLD, type(uint128).max, type(uint128).max, 1, true, true));
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        _expectRefused(
            _vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.TooManyOpen.selector, agentGrant)
        );
    }

    function test_attack_afterTheAgentExpires_bySubAgent_refused() public {
        ICrestVault.Caps memory c = _caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, true);
        c.expiresAt = uint40(block.timestamp + 1);
        _setAgentCaps(c);
        vm.warp(block.timestamp + 1);
        _expectRefused(
            _vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.Expired.selector, agentGrant)
        );
    }

    function test_attack_overTheRootsPerPayment_refused() public {
        vm.prank(principal);
        vault.setCaps(ROOT, _caps(HOLD - 1, type(uint128).max, type(uint128).max, 10, false, true), "");
        _expectRefused(
            _vterms(address(vault), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, ROOT)
        );
    }

    // A child vault past its parent's expiry (the PR tests stop, per-payment limit and list).

    function test_attack_childPaysAfterTheParentGrantExpires_refused() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vm.prank(buyer);
        vault.fundChild(address(child), HOLD, "");
        vm.prank(buyer);
        child.grant(ROOT, sub2, _wide(), 0, "");
        ICrestVault.Caps memory c = _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, true);
        c.expiresAt = uint40(block.timestamp + 1);
        _setAgentCaps(c);
        vm.warp(block.timestamp + 1);
        _expectRefused(
            _vterms(address(child), sub2), SUB2_PK, abi.encodeWithSelector(ICrestVault.Expired.selector, agentGrant)
        );
    }

    // A payee other than the pinned one.

    function test_attack_moduleEnabledWithAnotherPayee_fundingRefused_nothingCounted() public {
        vm.prank(principal);
        vault.setModule(address(module), stranger, "");
        H.Terms memory t = _vterms(address(vault), buyer);
        _expectRefused(t, BUYER_PK, bytes("MockERC3009: invalid signature"));
        assertEq(_grantOf(vault, agentGrant).spent, 0);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    // A commitment released twice.

    function test_attack_releaseTwice_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        _release(t, id);
        module.close(t);
        vm.expectRevert(ICrestVault.NotOpen.selector);
        module.close(t);
        assertEq(_grantOf(vault, ROOT).open, 0);
    }

    // The approval: an approved digest asked by a caller that is not the token, and used twice. The PR's test asks
    // about a digest that was never approved, so it passes whether or not the vault checks the caller.

    bytes32 internal constant NONCE = keccak256("review nonce");

    function _chargeAsModule(uint256 amount) internal returns (bytes32 digest) {
        vm.prank(principal);
        vault.setModule(address(this), address(this), ""); // this test is a module whose pinned payee is itself
        uint256 validBefore = block.timestamp + 1 hours;
        vault.charge(buyer, amount, _merchant(), keccak256("review commitment"), validBefore, NONCE);
        digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                        address(vault),
                        address(this),
                        amount,
                        0,
                        validBefore,
                        NONCE
                    )
                )
            )
        );
    }

    function test_attack_anApprovedDigestAskedByANonToken_answersNo() public {
        bytes32 digest = _chargeAsModule(HOLD);
        assertEq(vault.isValidSignature(digest, ""), bytes4(0xffffffff), "a caller that is not the token");
        vm.prank(stranger);
        assertEq(vault.isValidSignature(digest, ""), bytes4(0xffffffff), "a stranger");
        vm.prank(address(usdc));
        assertEq(vault.isValidSignature(digest, ""), bytes4(0x1626ba7e), "the token, for the approved digest");
    }

    function test_attack_theApprovalUsedTwiceOrForMore_refused() public {
        _chargeAsModule(HOLD);
        uint256 validBefore = block.timestamp + 1 hours;
        vm.expectRevert(bytes("MockERC3009: invalid signature"));
        usdc.receiveWithAuthorization(address(vault), address(this), HOLD + 1, 0, validBefore, NONCE, new bytes(65));
        usdc.receiveWithAuthorization(address(vault), address(this), HOLD, 0, validBefore, NONCE, new bytes(65));
        assertEq(usdc.balanceOf(address(this)), HOLD, "exactly the charged amount, once");
        vm.expectRevert(bytes("MockERC3009: authorization is used"));
        usdc.receiveWithAuthorization(address(vault), address(this), HOLD, 0, validBefore, NONCE, new bytes(65));
    }

    // Input validation: an amount above 128 bits, a zero period through setCaps.

    function test_attack_anAmountAbove128Bits_refused() public {
        _setAgentCaps(_wide());
        vm.prank(principal);
        vault.setModule(address(this), address(this), "");
        bytes32 merchant = _merchant(); // an external call: made before the expected revert
        vm.expectRevert(ICrestVault.AmountTooLarge.selector);
        vault.charge(buyer, uint256(type(uint128).max) + 1, merchant, keccak256("big"), block.timestamp + 1, NONCE);
    }

    function test_attack_aZeroPeriodThroughSetCaps_refused() public {
        ICrestVault.Caps memory c = _wide();
        c.period = 0;
        vm.prank(principal);
        vm.expectRevert(ICrestVault.InvalidCaps.selector);
        vault.setCaps(agentGrant, c, "");
    }

    // A child sends money up only: the PR's test checks the child's balance, not where the money went.

    function test_attack_childReturnsToTheCaller_notTheParent_refused() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vm.prank(buyer);
        vault.fundChild(address(child), HOLD, "");
        uint256 parentBefore = usdc.balanceOf(address(vault));
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        child.returnToParent(HOLD, "");
        assertEq(usdc.balanceOf(address(vault)) - parentBefore, HOLD, "the money reached the parent");
        assertEq(usdc.balanceOf(buyer), buyerBefore, "the caller got nothing");
    }

    // Handover: the previous principal loses the root for payments too, not only for withdraw.

    function test_attack_previousPrincipalPaysThroughTheRootAfterTheHandover_refused() public {
        address next = makeAddr("next principal");
        vm.prank(principal);
        vault.proposePrincipal(next, "");
        vm.prank(next);
        vault.acceptPrincipal("");
        _expectRefused(
            _vterms(address(vault), principal), PRINCIPAL_PK, abi.encodeWithSelector(ICrestVault.NoGrant.selector)
        );
    }

    // The module's nonce and the vault's digest equal what the collector presents, for any representable terms.

    function testFuzz_fundingThroughTheModule_matchesTheCollector(
        uint120 price,
        uint120 fee,
        uint32 g1,
        uint32 g2,
        uint32 g3,
        uint32 g4,
        uint32 appealDecideSec,
        address payout
    ) public {
        vm.assume(payout != address(0));
        // The escrow refuses a hold of 0 (`ZeroAmount`), before the vault matters: the price is at least 1.
        price = uint120(bound(price, 1, type(uint120).max / 2));
        fee = uint120(bound(fee, 0, type(uint120).max / 2));
        H.Terms memory t = _vterms(address(vault), buyer);
        t.price = price;
        t.fee = fee;
        t.sellerPayoutAddress = payout;
        t.timing.fundBy = t.timing.offerExpiresAt + uint64(bound(g1, 1, type(uint32).max));
        t.timing.deliverBy = t.timing.fundBy + uint64(bound(g2, 1, type(uint32).max));
        t.timing.judgeBy = t.timing.deliverBy + uint64(bound(g3, 1, type(uint32).max));
        t.timing.fallbackBy = t.timing.judgeBy + uint64(bound(g4, 1, type(uint32).max));
        t.timing.appealDecideSec = uint64(bound(appealDecideSec, 1, type(uint32).max));
        _setAgentCaps(_wide());
        usdc.mint(address(vault), uint256(price) + fee);
        bytes32 id = _fundVia(t, BUYER_PK);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
        (, uint120 held,) = escrow.paymentState(escrow.getHash(_pi(t)));
        assertEq(held, uint256(price) + fee, "the escrow holds exactly the hold");
        assertEq(_grantOf(vault, agentGrant).spent, uint256(price) + fee, "the grant counted exactly the hold");
    }

    // close() before the end, after a decision to escalate (stage Escalated is not an end).

    function test_closeWhileEscalated_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        _deliver(t, id);
        rules.decide(t, _primary(t, id, H.OUTCOME_ESCALATE), _noDelivery(), "");
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Escalated));
        vm.expectRevert(IHoldbackModule.NotEnded.selector);
        module.close(t);
    }
}
