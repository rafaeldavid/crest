// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {HoldbackModule} from "../../src/modules/holdback/HoldbackModule.sol";
import {IHoldbackModule} from "../../src/modules/holdback/IHoldbackModule.sol";
import {VaultBuyerBase} from "../VaultBuyerBase.sol";

/// Red team: signing for the vault when it is the deal's buyer (design record, section 12's attack list, and the
/// coordinator's seven points). Every `test_attack_*` passes when the defence holds and fails when the attack works.
contract RedTeamVaultBuyerTest is VaultBuyerBase {
    // Section 12, attack 1: the agent signs after a stop on its path

    function test_attack_theAgentSignsAfterAStopOnItsPath_refused() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop");
        _expectEarlyRefused(t, _earlyAs(t, id, BUYER_PK));
        _expectSettleRefused(t, _mutualAs(t, id, _fullRefund(t), BUYER_PK), IHoldbackRules.BadSignature.selector);
        vm.prank(principal);
        vault.setPaused(agentGrant, false, "resume");
        _acceptEarly(t, _earlyAs(t, id, BUYER_PK));
    }

    function test_attack_theAgentSignsAfterItsGrantExpired_refused() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        ICrestVault.Caps memory c = _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, true);
        c.expiresAt = uint40(vm.getBlockTimestamp() + 1);
        _setAgentCaps(c);
        vm.warp(vm.getBlockTimestamp() + 1);
        _expectEarlyRefused(t, _earlyAs(t, id, BUYER_PK));
    }

    /// A paused controller above a grant has authority to manage it but not to sign for it: the agent, paused, signs
    /// for a deal its live sub-agent opened, and is refused.
    function test_attack_aPausedControllerAboveSignsForADealBelow_refused() public {
        vm.prank(buyer);
        vault.grant(agentGrant, sub, _wide(), 0, "");
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, SUB_PK);
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop the agent and all below it");
        _expectEarlyRefused(t, _earlyAs(t, id, BUYER_PK));
        _expectEarlyRefused(t, _earlyAs(t, id, SUB_PK));
    }

    // Attacks 2 and 3: a stranger, and another agent in the same vault

    function test_attack_aStrangerSigns_refused() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        _expectEarlyRefused(t, _earlyAs(t, id, OTHER_PK));
        _expectFundRefused(
            _bterms(vault), _agreeAs(_bterms(vault), OTHER_PK), abi.encodeWithSelector(ICrestVault.NoGrant.selector)
        );
    }

    function test_attack_anotherAgentInTheVaultSignsForADealItDidNotOpen_refused() public {
        vm.prank(principal);
        vault.grant(ROOT, sub2, _wide(), 0, "");
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        _expectEarlyRefused(t, _earlyAs(t, id, SUB2_PK));
        _expectSettleRefused(t, _mutualAs(t, id, _fullRefund(t), SUB2_PK), IHoldbackRules.BadSignature.selector);
    }

    // Attacks 4 and 5: a signature replayed on another deal; fields that name another deal

    function test_attack_thePrincipalsSignatureOnOneDeal_replayedOnAnother_refused() public {
        H.Terms memory t1 = _bterms(vault);
        bytes32 id1 = _fundAs(t1, BUYER_PK);
        H.Terms memory t2 = _bterms(vault);
        bytes32 id2 = _fundAs(t2, BUYER_PK);
        Early memory e1 = _earlyAs(t1, id1, PRINCIPAL_PK);
        Early memory e2 = _earlyAs(t2, id2, PRINCIPAL_PK);
        e2.m.signature = e1.m.signature;
        _expectEarlyRefused(t2, e2);
    }

    /// The ECDSA signature covers deal 2's early accept; the message inside the blob rebuilds deal 1's.
    function test_attack_fieldsThatNameAnotherDealThanTheDigest_refused() public {
        H.Terms memory t1 = _bterms(vault);
        bytes32 id1 = _fundAs(t1, BUYER_PK);
        H.Terms memory t2 = _bterms(vault);
        bytes32 id2 = _fundAs(t2, BUYER_PK);
        Early memory e1 = _earlyAs(t1, id1, BUYER_PK);
        Early memory e2 = _earlyAs(t2, id2, BUYER_PK);
        e2.m.signature = abi.encode(
            address(module),
            abi.encodeCall(module.earlyAcceptMessage, (id1, t1.buyer, e1.m)),
            _ecdsa(BUYER_PK, _earlyDigest(t2, id2, e2.m))
        );
        _expectEarlyRefused(t2, e2);
    }

    // Attack 6 and point 5: a disabled module, and what ends a funded deal then

    /// After the principal disables the module, neither the agent nor the principal can sign for the buyer. The
    /// adjudicator's decision ends one deal, and the delivery deadline the other: both refund the vault, the decision
    /// less its fee to the adjudicator.
    function test_attack_afterTheModuleIsDisabled_noOneSignsForTheBuyer_andTheTermsStillEndTheDeals() public {
        uint256 before = usdc.balanceOf(address(vault));
        H.Terms memory t1 = _bterms(vault);
        bytes32 id1 = _fundAs(t1, BUYER_PK);
        H.Terms memory t2 = _bterms(vault);
        bytes32 id2 = _fundAs(t2, BUYER_PK);
        vm.prank(principal);
        vault.setModule(address(module), address(0), "module off");

        _expectEarlyRefused(t1, _earlyAs(t1, id1, BUYER_PK));
        _expectEarlyRefused(t1, _earlyAs(t1, id1, PRINCIPAL_PK));
        _expectSettleRefused(
            t2, _mutualAs(t2, id2, _fullRefund(t2), PRINCIPAL_PK), IHoldbackRules.BadSignature.selector
        );

        _deliver(t1, id1);
        rules.decide(t1, _primary(t1, id1, H.OUTCOME_REJECT), _noDelivery(), "");
        assertEq(uint8(_stage(id1)), uint8(IHoldbackRules.Stage.Refunded));
        vm.warp(t2.timing.deliverBy);
        rules.reclaim(t2);
        assertEq(uint8(_stage(id2)), uint8(IHoldbackRules.Stage.Refunded));
        assertEq(
            usdc.balanceOf(address(vault)), before - FEE, "both holds came back, less the deciding adjudicator's fee"
        );
        module.close(t1);
        module.close(t2);
        assertEq(_grantOf(vault, agentGrant).open, 0);
    }

    // Attack 7: another domain, and a deal another vault pays

    function test_attack_aDigestUnderAnotherDomain_refused() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        Early memory e = _earlyAs(t, id, BUYER_PK);
        bytes32 otherDomain = keccak256("another EIP-712 domain");
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", otherDomain, hx.early(id, t.buyer, e.m)));
        bytes memory sig = abi.encode(
            address(module), abi.encodeCall(module.earlyAcceptMessage, (id, t.buyer, e.m)), _ecdsa(BUYER_PK, digest)
        );
        assertEq(vault.isValidSignature(digest, sig), NO_1271);
    }

    /// From review test R2. Another vault's deal: that vault says yes; this one says no to the same blob, and no to a
    /// message naming this vault whose digest does match, since this vault never paid the deal. The settlement digest
    /// does not name the buyer, so the same digest is asked of both vaults.
    function test_attack_aDealAnotherVaultPays_refused() public {
        CrestVault other = CrestVault(factory.create(stranger, address(usdc), bytes32("other")));
        address payee = module.payee();
        vm.startPrank(stranger);
        other.setModule(address(module), payee, "");
        other.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
        usdc.mint(address(other), 10 * HOLD);
        H.Terms memory t = _bterms(other);
        bytes32 id = _fundAs(t, BUYER_PK);

        H.Mutual memory m = _mutualAs(t, id, _fullRefund(t), BUYER_PK);
        bytes32 digest = _mutualDigest(t, id, m);
        assertEq(other.isValidSignature(digest, m.buyerSignature), MAGIC_1271, "the paying vault says yes");
        assertEq(vault.isValidSignature(digest, m.buyerSignature), NO_1271, "the blob names another buyer");
        bytes memory asThis = _wrap(abi.encodeCall(module.mutualMessage, (id, address(vault), m)), digest, BUYER_PK);
        assertEq(module.mutualMessage(id, address(vault), m).digest, digest, "the same settlement digest");
        assertEq(vault.isValidSignature(digest, asThis), NO_1271, "this vault never paid that deal");

        Early memory e = _earlyAs(t, id, BUYER_PK);
        bytes32 forThis = rules.typedDataHash(hx.early(id, address(vault), e.m));
        bytes memory early =
            _wrap(abi.encodeCall(module.earlyAcceptMessage, (id, address(vault), e.m)), forThis, BUYER_PK);
        assertEq(vault.isValidSignature(forThis, early), NO_1271, "never paid, with the digest matching");
    }

    // Attack 8: the token

    /// The token gets only the transient answer for the digest `charge` approved: a buyer blob that is valid for the
    /// rules contract, or the agent's raw signature, is a no when the token asks.
    function test_attack_aBuyerSignatureOfferedToTheToken_refused() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        Early memory e = _earlyAs(t, id, BUYER_PK);
        bytes32 digest = _earlyDigest(t, id, e.m);
        assertEq(vault.isValidSignature(digest, e.m.signature), MAGIC_1271, "valid for anyone else");
        vm.prank(address(usdc));
        assertEq(vault.isValidSignature(digest, e.m.signature), NO_1271, "never for the token");
        vm.prank(address(usdc));
        assertEq(vault.isValidSignature(digest, _ecdsa(BUYER_PK, digest)), NO_1271);
        bytes32 nonce = keccak256("steal");
        vm.prank(buyer);
        vm.expectRevert(bytes("MockERC3009: invalid signature"));
        usdc.receiveWithAuthorization(address(vault), buyer, HOLD, 0, type(uint256).max, nonce, e.m.signature);
    }

    // Attack 9: a sibling signs for another sub-agent's child vault

    function test_attack_aSiblingSignsForAnotherSubAgentsChildVault_refused() public {
        (CrestVault child,) = _agentChild(2 * HOLD);
        vm.prank(buyer);
        vault.grant(agentGrant, sub2, _wide(), bytes32("sibling"), "");
        H.Terms memory t = _bterms(child);
        bytes32 id = _fundAs(t, SUB_PK);
        _expectEarlyRefused(t, _earlyAs(t, id, SUB2_PK));
    }

    // A handover

    function test_attack_thePreviousPrincipalSignsAfterAHandover_refused() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        address next = vm.addr(SUB2_PK);
        vm.prank(principal);
        vault.proposePrincipal(next, "");
        vm.prank(next);
        vault.acceptPrincipal("");
        _expectEarlyRefused(t, _earlyAs(t, id, PRINCIPAL_PK));
        _acceptEarly(t, _earlyAs(t, id, SUB2_PK));
    }

    // Point 2: a stop between an operator's check and the chain

    function test_attack_aSignatureAnOperatorChecked_isRefusedOnChainAfterAStop_andNothingMoves() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        Early memory e = _earlyAs(t, id, BUYER_PK);
        bytes32 digest = _earlyDigest(t, id, e.m);
        assertEq(vault.isValidSignature(digest, e.m.signature), MAGIC_1271, "the operator's eth_call passes");

        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop");
        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        _expectEarlyRefused(t, e);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
        assertEq(usdc.balanceOf(seller), sellerBefore);
        assertEq(usdc.balanceOf(address(vault)), vaultBefore);
        _acceptEarly(t, _earlyAs(t, id, PRINCIPAL_PK));
    }

    // Point 4: malformed, short, oversized or misdirected signatures

    function test_attack_shortOrRawSignatures_areANo() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        bytes32 digest = _earlyDigest(t, id, _earlyAs(t, id, BUYER_PK).m);
        assertEq(vault.isValidSignature(digest, ""), NO_1271);
        assertEq(vault.isValidSignature(digest, new bytes(64)), NO_1271);
        assertEq(vault.isValidSignature(digest, _ecdsa(BUYER_PK, digest)), NO_1271, "the agent's own raw signature");
    }

    /// A blob that does not decode makes the call revert, which Holdback reads as a no; nothing moves.
    function test_attack_malformedOrOversizedSignatures_revert_andHoldbackRefuses() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        Early memory e = _earlyAs(t, id, BUYER_PK);
        bytes32 digest = _earlyDigest(t, id, e.m);
        bytes memory junk = new bytes(20_000);
        for (uint256 i; i < junk.length; i++) {
            junk[i] = 0xff;
        }
        bytes memory badOffsets = abi.encodePacked(uint256(uint160(address(module))), uint256(1 << 64), uint256(0x60));
        vm.expectRevert();
        vault.isValidSignature(digest, junk);
        vm.expectRevert();
        vault.isValidSignature(digest, badOffsets);

        e.m.signature = junk;
        _expectEarlyRefused(t, e);
        e.m.signature = badOffsets;
        _expectEarlyRefused(t, e);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
    }

    /// Bytes after a valid blob are not read: the digest and the signer decide, so padding changes nothing.
    function test_observe_bytesAfterAValidBlob_areIgnored() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        Early memory e = _earlyAs(t, id, BUYER_PK);
        bytes32 digest = _earlyDigest(t, id, e.m);
        assertEq(vault.isValidSignature(digest, bytes.concat(e.m.signature, new bytes(1_000))), MAGIC_1271);
    }

    /// A blob naming a module the principal never enabled, a second enabled module that did not open the deal, or a
    /// module call that is not one of its message views.
    function test_attack_aBlobNamingAnotherModuleOrCall_refused() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        Early memory e = _earlyAs(t, id, BUYER_PK);
        bytes32 digest = _earlyDigest(t, id, e.m);
        bytes memory message = abi.encodeCall(module.earlyAcceptMessage, (id, t.buyer, e.m));

        HoldbackModule second = new HoldbackModule(rules, true);
        bytes memory viaSecond = abi.encode(address(second), message, _ecdsa(BUYER_PK, digest));
        assertEq(vault.isValidSignature(digest, viaSecond), NO_1271, "a module never enabled");
        address secondPayee = second.payee();
        vm.prank(principal);
        vault.setModule(address(second), secondPayee, "");
        assertEq(vault.isValidSignature(digest, viaSecond), NO_1271, "an enabled module that did not open the deal");

        bytes memory notAMessage = abi.encode(
            address(module),
            abi.encodeCall(module.counterpartyOf, (seller, adjudicator, fallbackAdj, appealAdj)),
            _ecdsa(BUYER_PK, digest)
        );
        vm.expectRevert();
        vault.isValidSignature(digest, notAMessage);
    }

    // Point 3: a starved call

    /// Through four levels of child vaults, the top principal's early accept is a yes with enough gas. Given less gas
    /// than the vault's answer needs, the call runs out and is a no; Holdback then refuses the early accept, and nothing
    /// moves. With enough gas the same signature lands.
    function test_attack_aStarvedBuyerAnswer_isANo_andHoldbackRefuses() public {
        _setAgentCaps(_caps(HOLD, type(uint128).max, type(uint128).max, 100, true, true));
        CrestVault at = vault;
        uint256 leafPk = BUYER_PK;
        uint256 leafGrant = agentGrant;
        for (uint256 depth = 1; depth <= 4; depth++) {
            (at, leafPk, leafGrant) = _deeper(at, leafPk, leafGrant, depth);
        }
        H.Terms memory t = _bterms(at);
        bytes32 id = _fundAs(t, leafPk);
        Early memory byTop = _earlyAs(t, id, PRINCIPAL_PK);
        bytes32 digest = _earlyDigest(t, id, byTop.m);
        assertEq(at.isValidSignature(digest, byTop.m.signature), MAGIC_1271);
        uint256 answer = vm.lastCallGas().gasTotalUsed;

        (bool ok, bytes memory ret) = address(at).staticcall{gas: answer / 2}(
            abi.encodeCall(ICrestVault.isValidSignature, (digest, byTop.m.signature))
        );
        assertTrue(!ok || abi.decode(ret, (bytes4)) != MAGIC_1271, "a starved call is never a yes");
        vm.expectRevert(IHoldbackRules.BadSignature.selector);
        rules.earlyAccept{gas: answer}(t, byTop.m, byTop.d, byTop.dsig, byTop.k);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held), "nothing moved");
        _acceptEarly(t, byTop);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Released));
    }

    // Review findings

    /// From review tests R1 and R1b. A stop on a child vault's root silences the child's principal (the agent), whose
    /// grant in the parent the child's root extends: it signs neither through the child nor through the parent. The top
    /// principal signs instead.
    function test_attack_aPauseOnAChildVaultsRoot_silencesItsPrincipal() public {
        _childRootStopped(false);
    }

    function test_attack_aCloseOfAChildVaultsRoot_silencesItsPrincipal() public {
        _childRootStopped(true);
    }

    function _childRootStopped(bool close) internal {
        (CrestVault child,) = _agentChild(2 * HOLD);
        H.Terms memory t = _bterms(child);
        bytes32 id = _fundAs(t, SUB_PK);
        vm.prank(principal);
        if (close) child.close(ROOT, "close the child vault");
        else child.setPaused(ROOT, true, "stop the child vault");

        assertFalse(child.signsFor(buyer, child.getOpen(id).grant), "the stopped root's controller");
        _expectEarlyRefused(t, _earlyAs(t, id, BUYER_PK));
        _expectEarlyRefused(t, _earlyAs(t, id, SUB_PK));
        _acceptEarly(t, _earlyAs(t, id, PRINCIPAL_PK));
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Released));
    }

    /// From review test R4. The terms digest is also the one Holdback asks its seller to sign, so a deal naming the vault
    /// as buyer and seller would let one agent key both offer and agree. The module refuses terms that name one party as
    /// both, so the vault cannot be its own seller.
    function test_attack_aDealNamingTheVaultAsBuyerAndSeller_refused() public {
        H.Terms memory t = _bterms(vault);
        t.seller = address(vault);
        bytes memory asSeller = _termsSig(t, BUYER_PK);
        bytes32 digest = rules.typedDataHash(hx.id(t));
        vm.expectRevert(IHoldbackModule.NotABuyerMessage.selector);
        vault.isValidSignature(digest, asSeller);
        H.Acceptance memory acc = _acceptance(t, ADJ_PK);
        H.Agree memory a = _agreeAs(t, BUYER_PK);
        vm.expectRevert(IHoldbackRules.BadSignature.selector);
        module.agreeAndFund(t, asSeller, acc, a, H.Funding({signature: new bytes(65)}));
        assertEq(_grantOf(vault, agentGrant).spent, 0, "nothing counted");
    }

    /// From review test R5. A plain 65-byte agreement for a vault buyer is refused by name.
    function test_attack_aRawAgreementForAVaultBuyer_refusedByName() public {
        H.Terms memory t = _bterms(vault);
        _expectFundRefused(t, _agree(t, BUYER_PK), abi.encodeWithSelector(IHoldbackModule.BadBuyerSignature.selector));
    }

    /// From review test R6. A grant that does not exist has no live path.
    function test_attack_aGrantThatDoesNotExist_hasNoLivePath() public view {
        assertEq(vault.getGrant(123_456_789).controller, address(0));
        assertFalse(vault.pathLive(123_456_789));
        assertFalse(vault.pathLive(0));
        assertFalse(vault.signsFor(stranger, 123_456_789));
    }

    /// From review test R10. A message shorter than a selector is refused by name.
    function test_attack_aMessageShorterThanASelector_isNotABuyerMessage() public {
        vm.expectRevert(IHoldbackModule.NotABuyerMessage.selector);
        module.buyerMessage(hex"aabbcc");
        vm.expectRevert(IHoldbackModule.NotABuyerMessage.selector);
        module.buyerMessage("");
    }

    /// From review test R9. A high-`s` twin of a valid signature is also a yes. Neither Holdback nor the vault uses a
    /// signature's bytes as an identity, so the twin gives nothing the original does not.
    function test_observe_aHighSTwinOfAValidSignature_isAlsoAYes() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        Early memory e = _earlyAs(t, id, BUYER_PK);
        bytes32 digest = _earlyDigest(t, id, e.m);
        (uint8 v, bytes32 r, bytes32 sLow) = vm.sign(BUYER_PK, digest);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory high = abi.encodePacked(r, bytes32(n - uint256(sLow)), v == 27 ? uint8(28) : uint8(27));
        bytes memory blob =
            abi.encode(address(module), abi.encodeCall(module.earlyAcceptMessage, (id, t.buyer, e.m)), high);
        assertEq(vault.isValidSignature(digest, blob), MAGIC_1271);
    }

    /// From review test R12. After the escrow's expiry anyone may end the commitment through the module, and the vault
    /// then signs for no one on that deal. The hold comes back by the escrow's payer-only `reclaim` (the vault's own) or
    /// Holdback's timeouts; after the escrow's expiry a settlement cannot pay the seller anyway.
    function test_observe_afterTheCommitmentEndsAtExpiry_theVaultSignsForNoOne() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        vm.warp(uint256(t.timing.fallbackBy) + t.timing.appealDecideSec + rules.EXPIRY_MARGIN());
        module.close(t);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held), "the rules contract still holds it");
        H.Mutual memory m = _mutualAs(t, id, _fullRefund(t), PRINCIPAL_PK);
        assertEq(vault.isValidSignature(_mutualDigest(t, id, m), m.buyerSignature), NO_1271);
        uint256 before = usdc.balanceOf(address(vault));
        vault.reclaim(address(module), _pi(t));
        assertEq(usdc.balanceOf(address(vault)) - before, HOLD, "the hold came back to the vault");
    }
}
