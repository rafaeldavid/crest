// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../src/CrestVault.sol";
import {ICrestVault} from "../src/ICrestVault.sol";
import {HoldbackModule} from "../src/modules/holdback/HoldbackModule.sol";
import {IHoldbackModule} from "../src/modules/holdback/IHoldbackModule.sol";
import {CrestBase} from "./CrestBase.sol";

/// A vault pays Holdback holds through the module, inside its limits, against Holdback's unchanged rules contract.
/// Every `test_attack_*` is an attempt to break a limit, and must fail.
contract HoldbackModuleTest is CrestBase {
    // Inside the limits

    function test_insideLimits_fundsHeld_thenReleased_andCloseFreesTheSlot() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        uint256 before = usdc.balanceOf(address(vault));
        bytes32 id = _fundVia(t, BUYER_PK);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
        assertEq(before - usdc.balanceOf(address(vault)), HOLD, "the vault paid the hold");
        assertEq(_grantOf(vault, agentGrant).open, 1);
        assertEq(_grantOf(vault, ROOT).open, 1, "every level counts");

        uint256 sellerBefore = usdc.balanceOf(seller);
        _release(t, id);
        assertEq(usdc.balanceOf(seller) - sellerBefore, PRICE, "the approved merchant was paid");

        module.close(t);
        assertEq(_grantOf(vault, agentGrant).open, 0);
        assertEq(_grantOf(vault, ROOT).open, 0);
        assertEq(_grantOf(vault, agentGrant).spent, HOLD, "what was spent stays counted");
    }

    function test_closeBeforeTheDealEnds_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        _fundVia(t, BUYER_PK);
        vm.expectRevert(IHoldbackModule.NotEnded.selector);
        module.close(t);
    }

    function test_refundReturnsToTheVault_andDoesNotGiveTheDayBack() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        uint256 afterFunding = usdc.balanceOf(address(vault));
        _deliver(t, id);
        rules.decide(t, _primary(t, id, H.OUTCOME_REJECT), _noDelivery(), "");
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Refunded));
        assertEq(
            usdc.balanceOf(address(vault)) - afterFunding, PRICE, "the price came back; the fee paid the adjudicator"
        );
        module.close(t);
        assertEq(_grantOf(vault, agentGrant).inPeriod, HOLD, "gross: the refund does not give the day back");
    }

    function test_dayBoundary_oneSecondBeforeRefused_atTheBoundaryFunds() public {
        _setAgentCaps(_caps(HOLD, 2 * HOLD, type(uint128).max, 10, true, true));
        uint256 dayEnd = (block.timestamp / 1 days + 1) * 1 days;
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        vm.warp(dayEnd - 1);
        _expectRefused(
            _vterms(address(vault), buyer),
            BUYER_PK,
            abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentGrant)
        );
        vm.warp(dayEnd);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
    }

    // Each limit, attacked

    function test_attack_overPerDeal_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        t.price = PRICE + 1;
        _expectRefused(t, BUYER_PK, abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, agentGrant));
    }

    function test_attack_overPerDay_refused() public {
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, true));
        for (uint256 i; i < 3; i++) {
            _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        }
        _expectRefused(
            _vterms(address(vault), buyer),
            BUYER_PK,
            abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentGrant)
        );
    }

    function test_attack_overLifetime_refused() public {
        _setAgentCaps(_caps(HOLD, type(uint128).max, 2 * HOLD, 10, true, true));
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        vm.warp(block.timestamp + 2 days);
        _expectRefused(
            _vterms(address(vault), buyer),
            BUYER_PK,
            abi.encodeWithSelector(ICrestVault.OverLifetime.selector, agentGrant)
        );
    }

    function test_attack_tooManyOpen_refused_untilOneCloses() public {
        H.Terms memory t1 = _vterms(address(vault), buyer);
        bytes32 id1 = _fundVia(t1, BUYER_PK);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        _expectRefused(
            _vterms(address(vault), buyer),
            BUYER_PK,
            abi.encodeWithSelector(ICrestVault.TooManyOpen.selector, agentGrant)
        );
        _release(t1, id1);
        module.close(t1);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
    }

    function test_attack_unlistedPayoutAddress_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        t.sellerPayoutAddress = vm.addr(OTHER_PK);
        _expectRefused(t, BUYER_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant));
    }

    function test_attack_listedPayoutWithAnotherAdjudicator_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        t.fallbackAdjudicator = vm.addr(OTHER_PK);
        _expectRefused(t, BUYER_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant));
    }

    function test_attack_afterPause_refused_andTheAgentCannotResume() public {
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "");
        _expectRefused(
            _vterms(address(vault), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant)
        );
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setPaused(agentGrant, false, "");
        vm.prank(principal);
        vault.setPaused(agentGrant, false, "");
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
    }

    function test_attack_afterThePrincipalPausesTheRoot_refused() public {
        vm.prank(principal);
        vault.setPaused(ROOT, true, "");
        _expectRefused(
            _vterms(address(vault), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.Paused.selector, ROOT)
        );
    }

    function test_attack_afterClose_refusedForGood_andTheKeyIsFreed() public {
        vm.prank(buyer);
        vault.close(agentGrant, "done with this agent");
        // the closed grant gives its key nothing: the key holds no grant now
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.NoGrant.selector));
        assertEq(vault.grantOf(buyer), 0, "closing frees the key");
        vm.prank(principal);
        vault.setPaused(agentGrant, false, "");
        assertTrue(vault.getGrant(agentGrant).closed, "a close is for good");
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.NoGrant.selector));
    }

    function test_attack_expiredGrant_refused() public {
        ICrestVault.Caps memory c = _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, true);
        c.expiresAt = uint40(block.timestamp + 1 hours);
        _setAgentCaps(c);
        vm.warp(block.timestamp + 1 hours);
        _expectRefused(
            _vterms(address(vault), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.Expired.selector, agentGrant)
        );
    }

    function test_attack_keyWithNoGrant_refused() public {
        H.Terms memory t = _vterms(address(vault), vm.addr(OTHER_PK));
        _expectRefused(t, OTHER_PK, abi.encodeWithSelector(ICrestVault.NoGrant.selector));
    }

    function test_attack_moduleNotEnabled_refused() public {
        HoldbackModule other = new HoldbackModule(rules);
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, BUYER_PK);
        vm.expectRevert(ICrestVault.ModuleNotEnabled.selector);
        other.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)}));
        vm.prank(principal);
        vault.setModule(address(module), address(0), "");
        _expectRefused(
            _vterms(address(vault), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.ModuleNotEnabled.selector)
        );
    }

    function test_attack_fundingStraightToTheRulesContract_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, BUYER_PK);
        // With any 65 bytes: the vault approved nothing.
        vm.expectRevert();
        rules.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)}));
        // With the agent's own signature over the exact funding: the vault still answers no.
        H.Funding memory own = _erc3009(t, BUYER_PK);
        vm.expectRevert();
        rules.agreeAndFund(t, s, a, ag, own);
        assertEq(_grantOf(vault, agentGrant).spent, 0);
    }

    function test_attack_erc6492FundingSignature_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, BUYER_PK);
        vm.expectRevert(IHoldbackModule.FundingSignatureNot65Bytes.selector);
        module.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(97)}));
    }

    function test_attack_agentSignsARawAuthorizationForTheVaultsMoney_refused() public {
        // The agent signs a ReceiveWithAuthorization moving the vault's money to itself, and submits it itself.
        bytes32 nonce = keccak256("steal");
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH, address(vault), buyer, HOLD, uint256(0), block.timestamp + 1, nonce
            )
        );
        bytes memory sig =
            _signRaw(BUYER_PK, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
        vm.prank(buyer);
        vm.expectRevert();
        usdc.receiveWithAuthorization(address(vault), buyer, HOLD, 0, block.timestamp + 1, nonce, sig);
    }

    function test_theVaultAnswersNoForADigestItNeverApproved() public view {
        bytes32 h = keccak256("anything");
        assertEq(vault.isValidSignature(h, ""), bytes4(0xffffffff), "not the token");
    }

    function test_attack_agentWithdraws_widens_listsOrEnables_refused() public {
        bytes32 itself = module.counterpartyOf(buyer, adjudicator, fallbackAdj, appealAdj);
        vm.startPrank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.withdraw(buyer, HOLD, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setCaps(agentGrant, _wide(), "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.allow(agentGrant, itself, true, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setModule(address(this), buyer, "");
        vm.stopPrank();
    }

    function test_attack_strangerGrantsOrPauses_refused() public {
        vm.startPrank(stranger);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grant(agentGrant, stranger, _wide(), 0, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setPaused(agentGrant, true, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.close(agentGrant, "");
        vm.stopPrank();
    }

    function test_attack_termsTheAgentNeverAgreed_countNothing() public {
        // A third party submits a deal for the vault with an agreement the agent's key did not sign.
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory forged = _agree(t, OTHER_PK);
        vm.prank(stranger);
        vm.expectRevert();
        module.agreeAndFund(t, s, a, forged, H.Funding({signature: new bytes(65)}));
        assertEq(_grantOf(vault, agentGrant).spent, 0, "a failed funding counts nothing");
        assertEq(_grantOf(vault, agentGrant).open, 0);
    }

    function test_attack_replayedFunding_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        _expectRefused(t, BUYER_PK, abi.encodeWithSelector(ICrestVault.CommitmentOpen.selector));
        _release(t, id);
        module.close(t);
        uint256 spent = _grantOf(vault, agentGrant).spent;
        _expectRefused(
            t, BUYER_PK, abi.encodeWithSelector(IHoldbackRules.WrongStage.selector, IHoldbackRules.Stage.Released)
        );
        assertEq(_grantOf(vault, agentGrant).spent, spent);
    }

    function test_attack_releaseByAnotherModule_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        vm.expectRevert(ICrestVault.NotOpen.selector);
        vault.endCommitment(id);
    }

    // Neutrality: nothing the principal does reaches money held for a deal.

    function test_neutrality_ownerEmptiesTheVaultAfterFunding_dealStillReleased() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        vm.startPrank(principal);
        vault.setPaused(ROOT, true, "");
        vault.setModule(address(module), address(0), "");
        vault.withdraw(principal, usdc.balanceOf(address(vault)), "");
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 0);
        uint256 sellerBefore = usdc.balanceOf(seller);
        _release(t, id);
        assertEq(usdc.balanceOf(seller) - sellerBefore, PRICE, "the seller is paid by the deal's terms");
    }

    function test_reclaimAfterTheEscrowsExpiry_returnsTheHoldToTheVault() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        _fundVia(t, BUYER_PK);
        uint256 afterFunding = usdc.balanceOf(address(vault));
        vm.warp(uint256(t.timing.fallbackBy) + t.timing.appealDecideSec + rules.EXPIRY_MARGIN());
        vault.reclaim(address(module), _pi(t));
        assertEq(usdc.balanceOf(address(vault)) - afterFunding, HOLD);
        module.close(t);
        assertEq(_grantOf(vault, agentGrant).open, 0);
    }

    function test_attack_reclaimForAnotherPayer_refused() public {
        H.Terms memory t = _terms(); // paid by the buyer's own key, not the vault
        AuthCaptureEscrow.PaymentInfo memory pi = _pi(t);
        vm.expectRevert(ICrestVault.NotThePayer.selector);
        vault.reclaim(address(module), pi);
    }

    // The gas of a funding through the vault, against a plain key's.

    function test_gas_fundingThroughTheVault_againstAPlainKey() public {
        H.Terms memory plain = _terms();
        uint256 g0 = gasleft();
        _fund(plain);
        uint256 plainGas = g0 - gasleft();
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, BUYER_PK);
        uint256 g1 = gasleft();
        module.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)}));
        emit log_named_uint("plain key funding, gas", plainGas);
        emit log_named_uint("vault funding at depth 1, gas", g1 - gasleft());
    }
}
