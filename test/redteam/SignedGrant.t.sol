// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IMulticall3} from "commerce-payments/interfaces/IMulticall3.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestList, ICrestVault} from "../../src/ICrestVault.sol";
import {RedTeamBase, RedTeamMulticall3} from "./RedTeamBase.sol";

/// A merchant list that allows every counterparty.
contract AllowEveryList {
    function allows(address, uint256, bytes32) external pure returns (bytes4) {
        return ICrestList.allows.selector;
    }
}

/// Code an EIP-7702 account delegates to. It would refuse every ERC-1271 question and counts every call it gets.
contract RefusingAccountCode {
    uint256 public calls;

    function isValidSignature(bytes32, bytes calldata) external returns (bytes4) {
        calls++;
        return 0xffffffff;
    }

    fallback() external payable {
        calls++;
    }
}

/// Red team: grants by a signature alone (`grantBySig`, `cancelSignedGrant`).
///
/// Every `test_attack_*` passes when the defence holds and fails when the attack works. A test that fails today says
/// so in its description, with the line in `src/` that lets it through.
contract RedTeamSignedGrantTest is RedTeamBase {
    bytes32 internal constant CAPS_TYPEHASH = keccak256(
        "Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    bytes32 internal constant SIGNED_GRANT_TYPEHASH = keccak256(
        "SignedGrant(uint256 parent,address controller,Caps caps,bytes32 salt,uint40 deadline,bytes note)Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 internal constant LOCAL_CHAIN = 31_337;
    uint256 internal constant STRANGER_PK = 0x5778;
    uint256 internal constant NEW_PRINCIPAL_PK = 0xBEEF5;

    // Helpers

    function _domainOf(address v, string memory name, string memory version, uint256 chainId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, v));
    }

    function _structHash(ICrestVault.SignedGrant memory s) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SIGNED_GRANT_TYPEHASH,
                s.parent,
                s.controller,
                keccak256(abi.encode(CAPS_TYPEHASH, s.caps)),
                s.salt,
                s.deadline,
                keccak256(s.note)
            )
        );
    }

    function _digestOn(address v, uint256 chainId, ICrestVault.SignedGrant memory s) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainOf(v, "Crest", "1", chainId), _structHash(s)));
    }

    function _sigOn(uint256 pk, address v, uint256 chainId, ICrestVault.SignedGrant memory s)
        internal
        pure
        returns (bytes memory)
    {
        (uint8 sv, bytes32 r, bytes32 ss) = vm.sign(pk, _digestOn(v, chainId, s));
        return abi.encodePacked(r, ss, sv);
    }

    function _sig(uint256 pk, address v, ICrestVault.SignedGrant memory s) internal pure returns (bytes memory) {
        return _sigOn(pk, v, LOCAL_CHAIN, s);
    }

    /// A slip with a 30-day deadline and a note.
    function _slipFor(uint256 parentId, address controller, ICrestVault.Caps memory caps, bytes32 salt)
        internal
        view
        returns (ICrestVault.SignedGrant memory s)
    {
        s = ICrestVault.SignedGrant({
            parent: parentId,
            controller: controller,
            caps: caps,
            salt: salt,
            deadline: uint40(vm.getBlockTimestamp() + 30 days),
            note: "red team"
        });
    }

    function _idOf(ICrestVault.SignedGrant memory s) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(s.parent, s.controller, s.salt)));
    }

    /// One deal of one hold, ever; no list of its own, so the agent's list above bounds whom it pays; no delegating.
    function _oneDeal() internal view returns (ICrestVault.Caps memory) {
        return _caps(HOLD, HOLD, HOLD, 1, false, false);
    }

    function _land(uint256 pk, CrestVault v, ICrestVault.SignedGrant memory s) internal returns (uint256) {
        return v.grantBySig(s, _sig(pk, address(v), s));
    }

    function _child() internal returns (CrestVault child) {
        vm.prank(buyer);
        child = CrestVault(vault.createChild(agentGrant, 0, ""));
    }

    // 1. An unused slip is a standing re-grant of its key

    /// The agent signed two slips for its sub-agent: a first and a spare (a retry, say). The first landed. The principal
    /// then pauses the sub-agent's grant to stop it. The sub-agent, alone, closes its own paused grant, which any
    /// controller may do, and lands the spare on its freed key: a fresh, unpaused grant, and the sub-agent pays again.
    /// Fails at 711c2aa: `grantBySig` (`src/CrestVault.sol:144`) refuses a key that holds a grant, but `close`
    /// (`src/CrestVault.sol:192`) frees the key, and a slip carries its signer's authority to whoever submits it until
    /// its deadline. (At 3d2c6f0 the spare landed without the close, through `_grant`'s close-and-continue.)
    function test_attack_subAgentEscapesAPauseOnItsOwnGrantWithASpareSlip_refused() public {
        ICrestVault.SignedGrant memory first = _slipFor(agentGrant, sub, _oneDeal(), "first");
        ICrestVault.SignedGrant memory spare = _slipFor(agentGrant, sub, _oneDeal(), "spare");
        bytes memory spareSig = _sig(BUYER_PK, address(vault), spare);
        uint256 g1 = _land(BUYER_PK, vault, first);
        vm.prank(principal);
        vault.setPaused(g1, true, "stop the sub-agent");

        vm.prank(sub);
        try vault.grantBySig(spare, spareSig) {}
        catch {
            vm.prank(sub);
            vault.close(g1, "");
            vm.prank(sub);
            try vault.grantBySig(spare, spareSig) {} catch {}
        }
        bool paid = _tryFundVia(_vterms(address(vault), sub), SUB_PK);

        assertFalse(paid, "the sub-agent paid after the principal paused its grant");
    }

    /// The principal closes the sub-agent's grant to end it. The sub-agent lands the spare slip and pays again. The
    /// principal could not cancel the spare first: `cancelSignedGrant` needs the slip's salt, which the agent chose off
    /// chain. Fails at 3d2c6f0 and 711c2aa: closing frees the key (`src/CrestVault.sol:192` at 711c2aa), and the spare
    /// lands on the freed key.
    function test_attack_subAgentReturnsAfterThePrincipalClosedItsGrant_refused() public {
        ICrestVault.SignedGrant memory first = _slipFor(agentGrant, sub, _oneDeal(), "first");
        ICrestVault.SignedGrant memory spare = _slipFor(agentGrant, sub, _oneDeal(), "spare");
        bytes memory spareSig = _sig(BUYER_PK, address(vault), spare);
        uint256 g1 = _land(BUYER_PK, vault, first);
        vm.prank(principal);
        vault.close(g1, "end the sub-agent");

        vm.prank(sub);
        try vault.grantBySig(spare, spareSig) {} catch {}
        bool paid = _tryFundVia(_vterms(address(vault), sub), SUB_PK);

        assertFalse(paid, "the sub-agent paid after the principal closed its grant");
    }

    /// The principal re-grants the sub-agent's key under its agent with a narrower limit, half a hold in all. A slip the
    /// agent signed earlier for the same key, a whole hold, is still unused. The sub-agent lands it (closing the
    /// principal's grant itself first if it must) and pays a whole hold. Fails at 3d2c6f0 and 711c2aa, for the reasons
    /// in the first test of this section.
    function test_attack_aSpareSlipUndoesThePrincipalsNarrowerRegrant_refused() public {
        ICrestVault.SignedGrant memory spare = _slipFor(agentGrant, sub, _oneDeal(), "spare");
        bytes memory spareSig = _sig(BUYER_PK, address(vault), spare);
        vm.startPrank(principal);
        uint256 narrow = vault.grant(
            agentGrant, sub, _caps(HOLD / 2, HOLD / 2, HOLD / 2, 1, true, false), bytes32("narrow"), "half a hold"
        );
        allowList.set(vault, narrow, _merchant(), true, "");
        vm.stopPrank();

        vm.prank(sub);
        try vault.grantBySig(spare, spareSig) {}
        catch {
            vm.prank(sub);
            vault.close(narrow, "");
            vm.prank(sub);
            try vault.grantBySig(spare, spareSig) {} catch {}
        }
        bool paid = _tryFundVia(_vterms(address(vault), sub), SUB_PK);

        assertFalse(paid, "the sub-agent paid past the principal's narrower grant");
    }

    /// The agent pre-signs three daily slips for its sub-agent, one deal each, with deadlines one, two and three days out:
    /// one deal a day. A slip has no start time, so on the first day the sub-agent lands all three in turn (closing its
    /// spent grant itself before each) and makes three deals. Fails at 3d2c6f0 and 711c2aa: `SignedGrant`
    /// (`src/ICrestVault.sol:92-100`) carries a deadline and no start, and a closed grant frees its key. The agent's own
    /// limits still bound the total.
    function test_attack_preSignedDailySlipsAllLandOnTheFirstDay_refused() public {
        _setAgentCaps(_caps(HOLD, 10 * HOLD, type(uint128).max, 10, true, true));
        uint256 spent;
        for (uint256 day = 1; day <= 3; ++day) {
            ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _oneDeal(), bytes32(day));
            s.deadline = uint40(vm.getBlockTimestamp() + day * 1 days);
            bytes memory sig = _sig(BUYER_PK, address(vault), s);
            uint256 held = vault.grantOf(sub);
            if (held != 0) {
                vm.prank(sub);
                vault.close(held, "spent");
            }
            vm.prank(sub);
            try vault.grantBySig(s, sig) returns (uint256 id) {
                if (_tryFundVia(_vterms(address(vault), sub), SUB_PK)) spent += _grantOf(vault, id).spent;
            } catch {}
        }
        emit log_named_uint("spent by the sub-agent on the first day, base units", spent);
        assertLe(spent, HOLD, "the sub-agent spent more than one day's deal on the first day");
    }

    /// What does stop a spare slip today: a stop on the signer's grant (a pause, or delegation turned off), or the
    /// principal moving the key out from under the signer.
    function test_aStopOnTheSignersGrantRefusesItsSpareSlips() public {
        ICrestVault.SignedGrant memory spare = _slipFor(agentGrant, sub, _oneDeal(), "spare");
        bytes memory sig = _sig(BUYER_PK, address(vault), spare);
        uint256 snap = vm.snapshotState();

        vm.prank(principal);
        vault.setPaused(agentGrant, true, "");
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant));
        vault.grantBySig(spare, sig);
        vm.revertToState(snap);

        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, false));
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grantBySig(spare, sig);
        vm.revertToState(snap);

        vm.prank(principal);
        vault.grant(ROOT, sub, _oneDeal(), bytes32("out of reach"), "");
        vm.expectRevert(ICrestVault.KeyNotFresh.selector);
        vault.grantBySig(spare, sig);
    }

    // 2. The signer's key moves, or the vault changes hands

    /// The agent signs a slip under its grant and one under its sub-agent's. The principal then moves the agent's key to
    /// a new grant, which closes the old one. Neither slip lands.
    function test_attack_aSlipSignedBeforeTheSignersKeyMoved_refused() public {
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _wide(), bytes32("sub"), "");
        ICrestVault.SignedGrant memory under = _slipFor(agentGrant, sub2, _oneDeal(), "under the agent");
        ICrestVault.SignedGrant memory below = _slipFor(subGrant, sub2, _oneDeal(), "under the sub-agent");
        bytes memory underSig = _sig(BUYER_PK, address(vault), under);
        bytes memory belowSig = _sig(BUYER_PK, address(vault), below);
        vm.prank(principal);
        vault.grant(ROOT, buyer, _wide(), bytes32("moved"), "the agent's key moves");

        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant));
        vault.grantBySig(under, underSig);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(below, belowSig);
        assertEq(vault.grantOf(sub2), 0);
    }

    /// The principal signs a slip under the root, then hands the vault over. The proposed principal signs one before it
    /// accepts. The old principal's slip never lands, even after the new principal gives the old key a grant; the new
    /// principal's lands only once it has accepted.
    function test_attack_slipsAcrossAHandover_landOnlyForTheCurrentPrincipal() public {
        address newPrincipal = vm.addr(NEW_PRINCIPAL_PK);
        ICrestVault.SignedGrant memory old = _slipFor(ROOT, sub, _wide(), "by the old principal");
        ICrestVault.SignedGrant memory early = _slipFor(ROOT, sub2, _wide(), "by the proposed principal");
        bytes memory oldSig = _sig(PRINCIPAL_PK, address(vault), old);
        bytes memory earlySig = _sig(NEW_PRINCIPAL_PK, address(vault), early);
        vm.prank(principal);
        vault.proposePrincipal(newPrincipal, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(early, earlySig);

        vm.prank(newPrincipal);
        vault.acceptPrincipal("");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(old, oldSig);
        vm.prank(newPrincipal);
        vault.grant(ROOT, principal, _wide(), bytes32("the old principal"), "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(old, oldSig);
        assertEq(vault.grantOf(sub), 0);

        vault.grantBySig(early, earlySig);
        assertEq(vault.grantOf(sub2), _idOf(early));
    }

    // 3. The top principal, which skips the delegation walk

    /// The principal's slip under a paused agent lands, as `grant` would, and pays nothing while the pause stands.
    function test_attack_topPrincipalsSlipUnderAPausedAgent_landsAndCannotPay() public {
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _oneDeal(), "top");
        bytes memory sig = _sig(PRINCIPAL_PK, address(vault), s);
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop the agent and all below it");
        vault.grantBySig(s, sig);
        _expectRefused(
            _vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant)
        );
    }

    /// The principal's slip under a closed grant is refused. Its slip under an open grant below the closed one lands, as
    /// `grant` would, and pays nothing.
    function test_attack_topPrincipalsSlipBelowAClosedGrant_cannotPay() public {
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _wide(), bytes32("sub"), "");
        ICrestVault.SignedGrant memory under = _slipFor(agentGrant, sub2, _oneDeal(), "under");
        ICrestVault.SignedGrant memory below = _slipFor(subGrant, sub2, _oneDeal(), "below");
        bytes memory underSig = _sig(PRINCIPAL_PK, address(vault), under);
        bytes memory belowSig = _sig(PRINCIPAL_PK, address(vault), below);
        vm.prank(principal);
        vault.close(agentGrant, "");

        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant));
        vault.grantBySig(under, underSig);
        vault.grantBySig(below, belowSig);
        _expectRefused(
            _vterms(address(vault), sub2), SUB2_PK, abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant)
        );
    }

    /// In a child vault no one is the top principal: the parent vault's principal signs there under the delegation walk.
    function test_attack_parentPrincipalsSlipInAChildVault_needsTheWholePath() public {
        CrestVault child = _child();
        ICrestVault.SignedGrant memory s = _slipFor(ROOT, sub, _wide(), "in the child");
        bytes memory sig = _sig(PRINCIPAL_PK, address(child), s);
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, false));
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        child.grantBySig(s, sig);
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, true));
        child.grantBySig(s, sig);
        assertEq(child.grantOf(sub), _idOf(s));
    }

    // 4. Child vaults

    /// In the agent's child vault, sub-agent 2 signs, and tries to cancel, for sub-agent 1's own child vault. Both are
    /// refused; sub-agent 1, that vault's principal, signs there.
    function test_attack_aSiblingSignsOrCancelsInAnotherSubAgentsChildVault_refused() public {
        CrestVault child = _child();
        vm.startPrank(buyer);
        uint256 subGrant = child.grant(ROOT, sub, _wide(), bytes32("sub"), "");
        child.grant(ROOT, sub2, _wide(), bytes32("sub2"), "");
        vm.stopPrank();
        vm.prank(sub);
        CrestVault grandchild = CrestVault(child.createChild(subGrant, 0, ""));
        address target = vm.addr(STRANGER_PK);
        ICrestVault.SignedGrant memory s = _slipFor(ROOT, target, _wide(), "sibling");

        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        grandchild.grantBySig(s, _sig(SUB2_PK, address(grandchild), s));
        vm.prank(sub2);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        grandchild.cancelSignedGrant(ROOT, target, s.salt, "");
        vm.prank(stranger);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        grandchild.cancelSignedGrant(ROOT, target, s.salt, "");

        grandchild.grantBySig(s, _sig(SUB_PK, address(grandchild), s));
        assertEq(grandchild.grantOf(target), _idOf(s));
    }

    /// The agent has two child vaults with the same principal (itself) and the same root. A slip for one does not land
    /// on the other, nor on the parent vault: only the domain tells them apart, and it does.
    function test_attack_aSlipForOneChildVaultOnItsTwin_refused() public {
        vm.startPrank(buyer);
        CrestVault one = CrestVault(vault.createChild(agentGrant, 0, ""));
        CrestVault twin = CrestVault(vault.createChild(agentGrant, bytes32(uint256(1)), ""));
        vm.stopPrank();
        assertTrue(address(one) != address(twin));
        ICrestVault.SignedGrant memory s = _slipFor(ROOT, sub, _wide(), "for one");
        bytes memory sig = _sig(BUYER_PK, address(one), s);

        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        twin.grantBySig(s, sig);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(s, sig);
        one.grantBySig(s, sig);
        assertEq(twin.grantOf(sub), 0);
    }

    /// A slip in the child vault grants the sub-agent wide limits and a list that allows every merchant. Its payments are
    /// still bound by the agent's grant in the parent vault: per payment and by its list.
    function test_attack_aSlipInAChildVaultPaysPastTheParentVaultsLimits_refused() public {
        CrestVault child = _child();
        vm.prank(buyer);
        vault.fundChild(address(child), 2 * HOLD, "");
        address otherPayout = makeAddr("other payout");
        ICrestVault.SignedGrant memory s = _slipFor(ROOT, sub, _wide(), "wide in the child");
        s.caps.list = address(new AllowEveryList());
        _land(BUYER_PK, child, s);

        H.Terms memory big = _vterms(address(child), sub);
        big.price = PRICE + 1;
        _expectRefused(big, SUB_PK, abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, agentGrant));
        H.Terms memory elsewhere = _vterms(address(child), sub);
        elsewhere.sellerPayoutAddress = otherPayout;
        _expectRefused(
            elsewhere, SUB_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant)
        );
    }

    function test_attack_aSlipInAChildVaultAfterTheParentGrantClosed_refused() public {
        CrestVault child = _child();
        ICrestVault.SignedGrant memory s = _slipFor(ROOT, sub, _wide(), "after the close");
        bytes memory sig = _sig(BUYER_PK, address(child), s);
        vm.prank(principal);
        vault.close(agentGrant, "");
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant));
        child.grantBySig(s, sig);
    }

    // 5. A wider list on the slip

    /// The agent's grant allows the test merchant only. Its slip points the sub-agent's grant at a list that allows every
    /// merchant, which `setCaps` could also do on that grant. A payment to a second merchant is refused at the agent's
    /// grant.
    function test_attack_aSlipListsAMerchantTheSignersGrantDoesNot_paymentRefused() public {
        address otherPayout = makeAddr("other payout");
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _oneDeal(), "list wider");
        s.caps.list = address(new AllowEveryList());
        _land(BUYER_PK, vault, s);
        H.Terms memory t = _vterms(address(vault), sub);
        t.sellerPayoutAddress = otherPayout;
        _expectRefused(t, SUB_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant));
    }

    // 6. The tombstone `cancelSignedGrant` writes

    /// The principal pauses the agent and will place a sub-agent under the agent's grant with a salt its tooling derives
    /// (0 here). The paused agent may not sign a slip there, yet it writes a tombstone at that ID first, and the
    /// principal's grant with that salt is refused. At 3d2c6f0 this contradicted the design ("anyone who may sign for
    /// that parent"); at 711c2aa the design accepts it (`docs/design.md:407`, "Who may cancel"), so this test observes
    /// it: no money moves, and another salt lands the principal's grant.
    function test_observe_aPausedAgentTakesAnIdThePrincipalWouldUse_anotherSaltLands() public {
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "investigating the agent");
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub2, _oneDeal(), bytes32(0));
        bytes memory sig = _sig(BUYER_PK, address(vault), s);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant));
        vault.grantBySig(s, sig);

        vm.prank(buyer);
        vault.cancelSignedGrant(agentGrant, sub2, bytes32(0), "");
        vm.prank(principal);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.grant(agentGrant, sub2, _oneDeal(), bytes32(0), "a sub-agent the principal places");
        vm.prank(principal);
        vault.grant(agentGrant, sub2, _oneDeal(), bytes32("another salt"), "");
        assertTrue(vault.grantOf(sub2) != 0);
    }

    /// A sub-agent, or a stranger, tries to void the agent's next slip by its ID. Both are refused.
    function test_attack_aSubAgentOrAStrangerVoidsTheAgentsNextSlip_refused() public {
        vm.prank(buyer);
        vault.grant(agentGrant, sub, _wide(), bytes32("sub"), "");
        ICrestVault.SignedGrant memory next = _slipFor(agentGrant, sub2, _oneDeal(), "next");
        vm.prank(sub);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.cancelSignedGrant(agentGrant, sub2, next.salt, "");
        vm.prank(stranger);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.cancelSignedGrant(agentGrant, sub2, next.salt, "");
        _land(BUYER_PK, vault, next);
        assertEq(vault.grantOf(sub2), _idOf(next));
    }

    /// The agent writes tombstones that name the principal's key and another agent's key. The named keys gain no
    /// authority from them and lose none: each keeps its grant, the other agent still pays, and closing the tombstone
    /// leaves its key's grant alone.
    function test_attack_aTombstoneNamingAnotherKey_givesAndTakesNothing() public {
        vm.startPrank(principal);
        uint256 sub2Grant = vault.grant(ROOT, sub2, _oneDeal(), bytes32("sub2"), "");
        allowList.set(vault, sub2Grant, _merchant(), true, "");
        vm.stopPrank();
        vm.startPrank(buyer);
        vault.cancelSignedGrant(agentGrant, principal, bytes32("t1"), "");
        vault.cancelSignedGrant(agentGrant, sub2, bytes32("t2"), "");
        vm.stopPrank();
        uint256 t1 = uint256(keccak256(abi.encode(agentGrant, principal, bytes32("t1"))));
        uint256 t2 = uint256(keccak256(abi.encode(agentGrant, sub2, bytes32("t2"))));
        assertEq(_grantOf(vault, t2).controller, sub2);
        assertTrue(_grantOf(vault, t2).closed);
        assertEq(vault.grantOf(principal), ROOT);
        assertEq(vault.grantOf(sub2), sub2Grant);

        vm.startPrank(sub2);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, t2));
        vault.grant(t2, stranger, _wide(), 0, "");
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, t2));
        vault.createChild(t2, 0, "");
        vault.close(t2, "");
        vm.stopPrank();
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, t1));
        vault.grant(t1, stranger, _wide(), 0, "");

        assertEq(vault.grantOf(sub2), sub2Grant);
        _fundVia(_vterms(address(vault), sub2), SUB2_PK);
        assertEq(_grantOf(vault, sub2Grant).spent, HOLD);
    }

    /// A tombstone's limits are all 0, its period included. No function divides by it: every path that reads a grant's
    /// limits checks `closed` first and reverts by name, `setCaps` reads only the new limits, and a tombstone is never a
    /// key's grant or a grant's parent. A cancel under a parent that does not exist is refused at 711c2aa; at 3d2c6f0 the
    /// principal could write one, and it walked up to nothing.
    function test_attack_aTombstonesZeroPeriodNeverDivides() public {
        vm.prank(buyer);
        vault.cancelSignedGrant(agentGrant, sub, bytes32("tomb"), "");
        uint256 tomb = uint256(keccak256(abi.encode(agentGrant, sub, bytes32("tomb"))));
        assertEq(_grantOf(vault, tomb).caps.period, 0);
        bytes memory closed = abi.encodeWithSelector(ICrestVault.GrantClosed.selector, tomb);
        bytes32 merchant = _merchant();

        vm.expectRevert(closed);
        vault.checkPath(tomb, 1, merchant);
        vm.expectRevert(closed);
        vault.checkDelegable(tomb);
        ICrestVault.SignedGrant memory s = _slipFor(tomb, sub2, _oneDeal(), "under a tombstone");
        bytes memory sig = _sig(PRINCIPAL_PK, address(vault), s);
        vm.expectRevert(closed);
        vault.grantBySig(s, sig);
        vm.prank(sub);
        vm.expectRevert(closed);
        vault.createChild(tomb, 0, "");
        _expectRefused(_vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.NoGrant.selector));

        ICrestVault.Caps memory zero = _wide();
        zero.period = 0;
        vm.startPrank(principal);
        vault.setCaps(tomb, _wide(), "");
        vm.expectRevert(ICrestVault.InvalidCaps.selector);
        vault.setCaps(tomb, zero, "");
        vault.setPaused(tomb, false, "");
        vm.stopPrank();
        assertTrue(_grantOf(vault, tomb).closed, "a tombstone reopened");

        vm.prank(principal);
        vm.expectRevert(ICrestVault.NoGrant.selector);
        vault.cancelSignedGrant(0xdead, sub, bytes32("nowhere"), "");
    }

    /// A cancel cannot write over a grant that exists, here or in a child vault, whoever sends it.
    function test_attack_aCancelAtALiveGrantsId_refused() public {
        vm.prank(principal);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.cancelSignedGrant(ROOT, buyer, 0, "");
        CrestVault child = _child();
        vm.prank(buyer);
        uint256 subGrant = child.grant(ROOT, sub, _wide(), bytes32("sub"), "");
        vm.prank(principal);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        child.cancelSignedGrant(ROOT, sub, bytes32("sub"), "");
        assertFalse(_grantOf(vault, agentGrant).closed);
        assertFalse(_grantOf(child, subGrant).closed);
    }

    // 7. Front-running

    /// The design suggests landing a slip and its first payment in one batch through Multicall3. Anyone who sees the
    /// batch can submit the slip alone first. A batch that requires every call reverts with it: the slip call fails
    /// with `GrantExists`. At 711c2aa the design tells a relayer to let the slip's call fail (`docs/design.md:408`), and
    /// then the payment lands: the front-runner only paid for the slip's gas.
    function test_attack_aFrontRunnerStopsTheFirstPaymentOfABatch_refused() public {
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _oneDeal(), "batch");
        bytes memory sig = _sig(BUYER_PK, address(vault), s);
        H.Terms memory t = _vterms(address(vault), sub);
        IMulticall3.Call[] memory calls = new IMulticall3.Call[](2);
        calls[0] = IMulticall3.Call(address(vault), abi.encodeCall(vault.grantBySig, (s, sig)));
        calls[1] = IMulticall3.Call(address(module), _fundCall(t, SUB_PK));

        vm.prank(stranger);
        vault.grantBySig(s, sig);
        vm.expectRevert("Multicall3: call failed");
        RedTeamMulticall3(MULTICALL3).tryAggregate(true, calls);
        IMulticall3.Result[] memory results = RedTeamMulticall3(MULTICALL3).tryAggregate(false, calls);

        assertFalse(results[0].success, "the slip landed twice");
        assertTrue(results[1].success, "a front-runner stopped the first payment of a batch that lets the slip fail");
    }

    /// The agent sends a cancel. The sub-agent sees it and lands the slip and a funding first, in one transaction. The
    /// cancel reverts by name, the agent's close then stops any further payment, and the hold already funded settles by
    /// its terms. A cancel races its slip, as any revocation of an off-chain signature does.
    function test_attack_theHolderWinsTheRaceAgainstACancel_andACloseStillStopsIt() public {
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _oneDeal(), "race");
        bytes memory sig = _sig(BUYER_PK, address(vault), s);
        H.Terms memory t = _vterms(address(vault), sub);
        IMulticall3.Call[] memory calls = new IMulticall3.Call[](2);
        calls[0] = IMulticall3.Call(address(vault), abi.encodeCall(vault.grantBySig, (s, sig)));
        calls[1] = IMulticall3.Call(address(module), _fundCall(t, SUB_PK));
        IMulticall3.Result[] memory results = RedTeamMulticall3(MULTICALL3).tryAggregate(true, calls);
        bytes32 deal = abi.decode(results[1].returnData, (bytes32));

        vm.prank(buyer);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.cancelSignedGrant(agentGrant, sub, s.salt, "too late");
        vm.prank(buyer);
        vault.close(_idOf(s), "");
        _expectRefused(_vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.NoGrant.selector));
        assertEq(uint8(_stage(deal)), uint8(IHoldbackRules.Stage.Held));
        _release(t, deal);
    }

    // 8. Signatures and their encoding

    /// Wallets sign EIP-712 from the type description, not from Crest's code. This slip's signature was made by
    /// `cast wallet sign --data` (Foundry 1.0.0, alloy's EIP-712) with the test buyer key, for a vault at 0xC0FFEE on
    /// chain 31337. The vault recovers that key, so its encoding is the standard one, with the counterparty array, the
    /// nested limits and the note.
    function test_attack_aSlipSignedByAStandardWallet_recoversItsSigner() public {
        address at = address(uint160(0xC0FFEE));
        vm.etch(at, address(vault).code);
        CrestVault v = CrestVault(at);
        v.initialize(principal, address(usdc), address(0), 0);
        vm.prank(principal);
        uint256 parentId = v.grant(ROOT, buyer, _wide(), 0, "");
        assertEq(parentId, 90916188481540811617180516143261187678914691542848256238469456329746153149125);
        ICrestVault.SignedGrant memory s = ICrestVault.SignedGrant({
            parent: parentId,
            controller: sub,
            caps: ICrestVault.Caps({
                perSpend: 26_500_000,
                perPeriod: 53_000_000,
                lifetime: type(uint128).max,
                maxOpen: 1,
                period: 86_400,
                expiresAt: 1_790_086_400,
                mayDelegate: false,
                list: address(0x1157)
            }),
            salt: bytes32("cast"),
            deadline: 1_790_003_600,
            note: "signed by cast"
        });
        bytes memory walletSig =
            hex"158b09077210ec4eedcb756e61aa81fa704544504aead67d943bde068eb2e2fe343639c2b64c400d7d5b896b3a8eb4d750b6d8c07a3d20b9cca4ae48df2ea50e1c";

        assertEq(v.grantBySig(s, walletSig), _idOf(s));
        assertEq(v.grantOf(sub), _idOf(s));
        assertEq(keccak256(walletSig), keccak256(_sig(BUYER_PK, at, s)), "this file's encoding is the wallet's");
    }

    /// Slips that a naive packed encoding would confuse (two limits swapped, or a list moved into the note) have
    /// different digests: one's signature does not land the other.
    function test_attack_twoSlipsThatPackAlike_doNotShareADigest() public {
        ICrestVault.SignedGrant memory d = _slipFor(agentGrant, sub, _oneDeal(), "twins");
        d.note = "";
        d.caps = _caps(HOLD, 2 * HOLD, HOLD, 1, true, false);
        ICrestVault.SignedGrant memory e = _slipFor(agentGrant, sub, _oneDeal(), "twins");
        e.note = "";
        e.caps = _caps(2 * HOLD, HOLD, HOLD, 1, false, true);
        ICrestVault.SignedGrant memory f = _slipFor(agentGrant, sub, _oneDeal(), "twins");
        f.caps = _caps(HOLD, 2 * HOLD, HOLD, 1, false, false);
        f.note = abi.encodePacked(address(allowList));
        bytes memory dSig = _sig(BUYER_PK, address(vault), d);

        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(e, dSig);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(f, dSig);
        vault.grantBySig(d, dSig);
    }

    /// A submitter rewrites the calldata of a valid slip with dirty bits in the padding of a signed field: the key, the
    /// most open commitments, a flag set to 2, the deadline. Each call reverts; the clean one lands.
    function test_attack_dirtyBitsInASignedField_refused() public {
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _oneDeal(), "dirty");
        bytes memory clean = abi.encodeCall(vault.grantBySig, (s, _sig(BUYER_PK, address(vault), s)));
        // Offsets in the calldata: the slip's tuple starts at 0x44; `controller` at 0x64, `caps.maxOpen` at 0xe4,
        // `caps.mayDelegate` at 0x144 (its last byte 0x163), `deadline` at 0x1a4.
        uint256[4] memory at = [uint256(0x64), 0xe4, 0x163, 0x1a4];
        uint8[4] memory put = [uint8(0x01), 0x01, 0x02, 0x01];
        for (uint256 i; i < 4; ++i) {
            bytes memory dirty = bytes.concat(clean);
            dirty[at[i]] = bytes1(put[i]);
            (bool ok,) = address(vault).call(dirty);
            assertFalse(ok, "the vault took a signed field with dirty bits");
        }
        assertEq(vault.grantOf(sub), 0);
        (bool landed,) = address(vault).call(clean);
        assertTrue(landed);
        assertEq(vault.grantOf(sub), _idOf(s));
    }

    /// The same struct signed under another name, another version, another verifying contract, no domain at all, or as
    /// an EIP-191 personal message of the right digest: none lands.
    function test_attack_aSignatureUnderAnotherDomainOrNone_refused() public {
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _oneDeal(), "domains");
        bytes32 sh = _structHash(s);
        bytes32[5] memory digests = [
            keccak256(abi.encodePacked("\x19\x01", _domainOf(address(vault), "Crest", "2", LOCAL_CHAIN), sh)),
            keccak256(abi.encodePacked("\x19\x01", _domainOf(address(vault), "Holdback", "1", LOCAL_CHAIN), sh)),
            keccak256(abi.encodePacked("\x19\x01", _domainOf(address(rules), "Crest", "1", LOCAL_CHAIN), sh)),
            sh,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", _digestOn(address(vault), LOCAL_CHAIN, s)))
        ];
        for (uint256 i; i < 5; ++i) {
            (uint8 v, bytes32 r, bytes32 ss) = vm.sign(BUYER_PK, digests[i]);
            vm.expectRevert(ICrestVault.NotAuthorized.selector);
            vault.grantBySig(s, abi.encodePacked(r, ss, v));
        }
        vault.grantBySig(s, _sig(BUYER_PK, address(vault), s));
    }

    /// A v of 0 or 1 (some signers' form), an r of 0, or 65 zero bytes: refused with `BadGrantSignature`, never as some
    /// other signer.
    function test_attack_aSignatureWithABadVOrR_refusedByName() public {
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _oneDeal(), "v");
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(BUYER_PK, _digestOn(address(vault), LOCAL_CHAIN, s));
        vm.expectRevert(ICrestVault.BadGrantSignature.selector);
        vault.grantBySig(s, abi.encodePacked(r, ss, v - 27));
        vm.expectRevert(ICrestVault.BadGrantSignature.selector);
        vault.grantBySig(s, abi.encodePacked(bytes32(0), ss, v));
        vm.expectRevert(ICrestVault.BadGrantSignature.selector);
        vault.grantBySig(s, new bytes(65));
        vault.grantBySig(s, abi.encodePacked(r, ss, v));
    }

    /// A vault is a contract that answers ERC-1271. The principal gives another vault's address a grant. No signature
    /// makes a slip under that grant: the slip path never asks ERC-1271, and a vault answers no one but its token.
    function test_attack_aVaultAsASignerByItsOwnIsValidSignature_refused() public {
        CrestVault other = CrestVault(factory.create(stranger, address(usdc), bytes32("another principal")));
        vm.prank(principal);
        uint256 vaultGrant = vault.grant(ROOT, address(other), _wide(), bytes32("a vault"), "");
        ICrestVault.SignedGrant memory s = _slipFor(vaultGrant, sub, _wide(), "by a vault");
        assertEq(other.isValidSignature(_digestOn(address(vault), LOCAL_CHAIN, s), ""), bytes4(0xffffffff));
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(s, _sig(STRANGER_PK, address(vault), s));
        vm.expectRevert(ICrestVault.BadGrantSignature.selector);
        vault.grantBySig(s, new bytes(65));
        assertEq(vault.grantOf(sub), 0);
    }

    /// The sub-agent's key is an EIP-7702 account whose code would refuse every ERC-1271 question. Its ECDSA slip lands,
    /// as a transaction from it would; another key's slip under its grant does not; its code is never called.
    function test_attack_anEip7702Signer_isJudgedByItsKeyAndItsCodeIsNeverAsked() public {
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _wide(), bytes32("sub"), "");
        RefusingAccountCode code = new RefusingAccountCode();
        vm.etch(sub, abi.encodePacked(hex"ef0100", address(code)));
        assertEq(RefusingAccountCode(payable(sub)).calls(), 0);
        ICrestVault.SignedGrant memory s = _slipFor(subGrant, sub2, _oneDeal(), "7702");
        ICrestVault.SignedGrant memory other = _slipFor(subGrant, vm.addr(STRANGER_PK), _oneDeal(), "not its key");

        vault.grantBySig(s, _sig(SUB_PK, address(vault), s));
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(other, _sig(STRANGER_PK, address(vault), other));

        assertEq(vault.grantOf(sub2), _idOf(s));
        assertEq(RefusingAccountCode(payable(sub)).calls(), 0, "the vault asked the account's code");
    }

    // 9. The chain ID and the clone's domain

    /// Each slip lands only on the chain it names, whichever way the chain ID changes, and `eip712Domain` reports the
    /// chain the clone runs on: the clone never uses the implementation's cached domain.
    function test_attack_theDomainFollowsAChainIdChangeBothWays() public {
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _oneDeal(), "chain");
        bytes memory here = _sigOn(BUYER_PK, address(vault), LOCAL_CHAIN, s);
        bytes memory there = _sigOn(BUYER_PK, address(vault), 11_155_111, s);
        vm.chainId(11_155_111);
        (,,, uint256 chainId, address verifying,,) = vault.eip712Domain();
        assertEq(chainId, 11_155_111);
        assertEq(verifying, address(vault));
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(s, here);
        uint256 snap = vm.snapshotState();
        vault.grantBySig(s, there);
        vm.revertToState(snap);

        vm.chainId(LOCAL_CHAIN);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(s, there);
        vault.grantBySig(s, here);
    }

    /// The implementation every clone runs has no grant and no principal anyone holds: a slip or a cancel on it is
    /// refused. (At 3d2c6f0 the cancel was refused with `NotAuthorized`; at 711c2aa its new parent check refuses first.)
    function test_attack_aSlipOrACancelOnTheImplementation_refused() public {
        CrestVault impl = CrestVault(factory.IMPLEMENTATION());
        ICrestVault.SignedGrant memory s = _slipFor(ROOT, sub, _wide(), "implementation");
        bytes memory sig = _sig(PRINCIPAL_PK, address(impl), s);
        vm.expectRevert(ICrestVault.NoGrant.selector);
        impl.grantBySig(s, sig);
        vm.prank(principal);
        vm.expectRevert(ICrestVault.NoGrant.selector);
        impl.cancelSignedGrant(ROOT, sub, s.salt, "");
    }

    // 10. Gas griefing

    /// The signer writes a 6,400-byte note to make the slip dear to use. The note costs whoever submits the slip, once;
    /// a payment through the grant costs the same with a short note or a long one.
    function test_attack_gasGriefingByALongNote_costsOnlyItsSubmitter() public {
        ICrestVault.SignedGrant memory a = _slipFor(agentGrant, sub, _oneDeal(), "short");
        ICrestVault.SignedGrant memory b = _slipFor(agentGrant, sub2, _oneDeal(), "long");
        b.note = new bytes(6_400);
        bytes memory aSig = _sig(BUYER_PK, address(vault), a);
        bytes memory bSig = _sig(BUYER_PK, address(vault), b);

        uint256 snap = vm.snapshotState();
        uint256 g = gasleft();
        vault.grantBySig(a, aSig);
        uint256 landShort = g - gasleft();
        vm.revertToState(snap);
        g = gasleft();
        vault.grantBySig(b, bSig);
        uint256 landLong = g - gasleft();
        vault.grantBySig(a, aSig);
        emit log_named_uint("a slip with a short note, execution gas", landShort);
        emit log_named_uint("a slip with a 6,400-byte note, execution gas", landLong);

        bytes memory callA = _fundCall(_vterms(address(vault), sub), SUB_PK);
        bytes memory callB = _fundCall(_vterms(address(vault), sub2), SUB2_PK);
        snap = vm.snapshotState();
        g = gasleft();
        (bool okA,) = address(module).call(callA);
        uint256 payShort = g - gasleft();
        vm.revertToState(snap);
        g = gasleft();
        (bool okB,) = address(module).call(callB);
        uint256 payLong = g - gasleft();
        assertTrue(okA && okB);
        assertApproxEqAbs(payLong, payShort, 3_000, "a long note made a payment dearer");
    }

    // 11. Money in a hold

    /// A sub-agent funds a hold through its slip's grant. Then the changes this pull request adds all run: a second slip
    /// for the same key (which today moves the key and closes the funded grant; where slips may not move a key, the agent
    /// moves it by transaction), the agent cancels a third, the principal closes the agent. The hold settles by its
    /// terms, to the listed payout address, and the module ends the commitment on the closed grant, so every open count
    /// falls back to 0.
    function test_attack_slipsAndCancelsAfterAFunding_theHoldSettlesByItsTerms() public {
        ICrestVault.SignedGrant memory first = _slipFor(agentGrant, sub, _oneDeal(), "funded");
        ICrestVault.SignedGrant memory second = _slipFor(agentGrant, sub, _oneDeal(), "moved");
        bytes memory secondSig = _sig(BUYER_PK, address(vault), second);
        uint256 g1 = _land(BUYER_PK, vault, first);
        H.Terms memory t = _vterms(address(vault), sub);
        bytes32 deal = _fundVia(t, SUB_PK);
        assertEq(_grantOf(vault, g1).open, 1);

        try vault.grantBySig(second, secondSig) {}
        catch {
            vm.prank(buyer);
            vault.grant(agentGrant, sub, _oneDeal(), bytes32("moved by transaction"), "");
        }
        assertTrue(_grantOf(vault, g1).closed);
        vm.prank(buyer);
        vault.cancelSignedGrant(agentGrant, sub2, bytes32("never used"), "");
        vm.prank(principal);
        vault.close(agentGrant, "");

        uint256 sellerBefore = usdc.balanceOf(seller);
        _release(t, deal);
        assertEq(usdc.balanceOf(seller) - sellerBefore, PRICE, "the listed payout address is paid");
        module.close(t);
        assertEq(_grantOf(vault, g1).open, 0);
        assertEq(_grantOf(vault, agentGrant).open, 0);
        assertEq(_grantOf(vault, ROOT).open, 0);
    }

    // 12. A slip names its signer or an ancestor

    /// A slip that names its own signer's key, its signer's ancestor or the principal is refused: a key holds one grant,
    /// and only authority above that grant may move it.
    function test_attack_aSlipNamingItsSignerOrAnAncestor_refused() public {
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _wide(), bytes32("sub"), "");
        ICrestVault.SignedGrant[] memory slips = new ICrestVault.SignedGrant[](5);
        slips[0] = _slipFor(agentGrant, buyer, _wide(), "self");
        slips[1] = _slipFor(subGrant, buyer, _wide(), "self, below");
        slips[2] = _slipFor(subGrant, buyer, _wide(), "the agent");
        slips[3] = _slipFor(subGrant, principal, _wide(), "the principal");
        slips[4] = _slipFor(agentGrant, principal, _wide(), "the principal, from the agent");
        uint256[5] memory signers = [BUYER_PK, BUYER_PK, SUB_PK, SUB_PK, BUYER_PK];
        for (uint256 i; i < 5; ++i) {
            bytes memory sig = _sig(signers[i], address(vault), slips[i]);
            vm.expectRevert(ICrestVault.KeyNotFresh.selector);
            vault.grantBySig(slips[i], sig);
        }
        assertEq(vault.grantOf(buyer), agentGrant);
        assertEq(vault.grantOf(sub), subGrant);
        assertEq(vault.grantOf(principal), ROOT);
    }

    // 13. A slip lands exactly where its signer's grant by transaction would

    /// From one state, the signer's grant by transaction followed by its `allow` of each listed counterparty, and the
    /// slip. A slip that lands leaves the same grant, key and list as the grant by transaction, which must land too. A
    /// slip for a fresh key (one that has never held a grant here) lands wherever the grant by transaction does, and is
    /// refused with the same revert where it does not. A slip for a key that holds or held a grant may be refused
    /// earlier, since a slip never moves a key at 711c2aa. The state is restored afterwards.
    function _sameAsByTransaction(
        CrestVault v,
        uint256 signerPk,
        uint256 parentId,
        address controller,
        ICrestVault.Caps memory caps,
        bytes32 salt
    ) internal returns (bool landed) {
        address signer = vm.addr(signerPk);
        ICrestVault.SignedGrant memory s = _slipFor(parentId, controller, caps, salt);
        bytes memory sig = _sig(signerPk, address(v), s);
        uint256 id = _idOf(s);
        uint256 held = v.grantOf(controller);
        uint256 snap = vm.snapshotState();

        vm.prank(signer);
        (bool okTx, bytes memory errTx) =
            address(v).call(abi.encodeCall(v.grant, (parentId, controller, caps, salt, s.note)));
        bytes32 afterTx = _stateOf(v, id, controller, held);
        vm.revertToState(snap);

        (bool okSig, bytes memory errSig) = address(v).call(abi.encodeCall(v.grantBySig, (s, sig)));
        bytes32 afterSig = _stateOf(v, id, controller, held);

        bool fresh = held == 0 && controller != buyer && controller != sub && controller != principal;
        if (okSig) {
            assertTrue(okTx, "a slip landed where its signer's grant by transaction would not");
            assertEq(afterSig, afterTx, "the slip left another state than the grant by transaction");
        } else if (okTx) {
            assertFalse(fresh, "a slip for a fresh key was refused where its signer's grant by transaction lands");
        } else if (fresh) {
            assertEq(errSig, errTx, "the slip was refused for another reason");
        }
        landed = okSig;
        vm.revertToState(snap);
    }

    function _stateOf(CrestVault v, uint256 id, address controller, uint256 held) internal view returns (bytes32) {
        return keccak256(abi.encode(v.getGrant(id), v.grantOf(controller), v.getGrant(held)));
    }

    function _signerKey(uint8 who) internal pure returns (uint256) {
        uint256[5] memory keys = [PRINCIPAL_PK, BUYER_PK, SUB_PK, SUB2_PK, STRANGER_PK];
        return keys[who % 5];
    }

    function _named(uint8 whom, address here) internal view returns (address) {
        address[7] memory keys = [sub2, vm.addr(STRANGER_PK), sub, buyer, principal, address(0), here];
        return keys[whom % 7];
    }

    function _saltOf(uint8 which, bytes32 free) internal pure returns (bytes32) {
        bytes32[4] memory salts = [free, bytes32("sub"), bytes32(0), bytes32("tomb")];
        return salts[which % 4];
    }

    /// The top vault, with a sub-agent under the agent and a tombstone. Flags: 1 pauses the agent, 2 closes it, 4 turns
    /// its delegation off, 8 pauses the sub-agent, 16 closes it, 32 expires the agent, 64 gives the slip a zero period,
    /// 128 turns the sub-agent's delegation off.
    function _topWorld(uint8 flags) internal returns (CrestVault, uint256[5] memory parents) {
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _caps(HOLD, HOLD, HOLD, 1, true, flags & 128 == 0), "sub", "");
        vm.prank(buyer);
        vault.cancelSignedGrant(agentGrant, sub2, "tomb", "");
        if (flags & 4 != 0 || flags & 32 != 0) {
            ICrestVault.Caps memory c = _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, flags & 4 == 0);
            if (flags & 32 != 0) c.expiresAt = uint40(vm.getBlockTimestamp());
            _setAgentCaps(c);
        }
        vm.startPrank(principal);
        if (flags & 1 != 0) vault.setPaused(agentGrant, true, "");
        if (flags & 8 != 0) vault.setPaused(subGrant, true, "");
        if (flags & 16 != 0) vault.close(subGrant, "");
        if (flags & 2 != 0) vault.close(agentGrant, "");
        vm.stopPrank();
        parents = [
            ROOT,
            agentGrant,
            subGrant,
            uint256(0xdead),
            uint256(keccak256(abi.encode(agentGrant, sub2, bytes32("tomb"))))
        ];
        return (vault, parents);
    }

    /// The agent's child vault, with a sub-agent in it and a tombstone. Flags: 1 pauses the agent in the parent vault, 2
    /// closes it, 4 turns its delegation off, 8 pauses the sub-agent in the child, 16 closes it, 32 pauses the child's
    /// root from the parent vault, 64 gives the slip a zero period, 128 turns the sub-agent's delegation off.
    function _childWorld(uint8 flags) internal returns (CrestVault child, uint256[5] memory parents) {
        child = _child();
        vm.startPrank(buyer);
        uint256 subGrant = child.grant(ROOT, sub, _caps(HOLD, HOLD, HOLD, 1, true, flags & 128 == 0), "sub", "");
        child.cancelSignedGrant(ROOT, sub2, "tomb", "");
        vm.stopPrank();
        if (flags & 4 != 0) _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, false));
        vm.startPrank(principal);
        if (flags & 1 != 0) vault.setPaused(agentGrant, true, "");
        if (flags & 8 != 0) child.setPaused(subGrant, true, "");
        if (flags & 16 != 0) child.close(subGrant, "");
        if (flags & 32 != 0) child.setPaused(ROOT, true, "");
        if (flags & 2 != 0) vault.close(agentGrant, "");
        vm.stopPrank();
        parents =
            [ROOT, subGrant, uint256(0xdead), agentGrant, uint256(keccak256(abi.encode(ROOT, sub2, bytes32("tomb"))))];
    }

    function _compare(
        CrestVault v,
        uint256[5] memory parents,
        uint8 who,
        uint8 under,
        uint8 whom,
        uint8 flags,
        bytes32 salt
    ) internal returns (bool landed) {
        uint256 fmp;
        assembly {
            fmp := mload(0x40)
        }
        ICrestVault.Caps memory caps = _oneDeal();
        if (flags & 64 != 0) caps.period = 0;
        landed = _sameAsByTransaction(v, _signerKey(who), parents[under % 5], _named(whom, address(v)), caps, salt);
        assembly {
            mstore(0x40, fmp)
        }
    }

    /// forge-config: default.fuzz.runs = 4096
    function testFuzz_attack_aSlipLandsExactlyWhereItsSignersGrantWould(
        uint8 who,
        uint8 under,
        uint8 whom,
        uint8 flags,
        uint8 which,
        bytes32 free
    ) public {
        (CrestVault v, uint256[5] memory parents) = _topWorld(flags);
        _compare(v, parents, who, under, whom, flags, _saltOf(which, free));
    }

    /// forge-config: default.fuzz.runs = 4096
    function testFuzz_attack_aSlipInAChildVaultLandsExactlyWhereItsSignersGrantWould(
        uint8 who,
        uint8 under,
        uint8 whom,
        uint8 flags,
        uint8 which,
        bytes32 free
    ) public {
        (CrestVault v, uint256[5] memory parents) = _childWorld(flags);
        _compare(v, parents, who, under, whom, flags, _saltOf(which, free));
    }

    /// Every signer, parent and named key in the table (5 x 5 x 7), with no flag and with each flag alone.
    function _table(bool inChild) internal {
        uint8[9] memory flagSets = [uint8(0), 1, 2, 4, 8, 16, 32, 64, 128];
        uint256 landed;
        uint256 refused;
        for (uint256 f; f < 9; ++f) {
            uint256 s0 = vm.snapshotState();
            (CrestVault v, uint256[5] memory parents) = inChild ? _childWorld(flagSets[f]) : _topWorld(flagSets[f]);
            for (uint8 who; who < 5; ++who) {
                for (uint8 under; under < 5; ++under) {
                    for (uint8 whom; whom < 7; ++whom) {
                        if (_compare(v, parents, who, under, whom, flagSets[f], bytes32("table"))) ++landed;
                        else ++refused;
                    }
                }
            }
            vm.revertToState(s0);
        }
        emit log_named_uint("comparisons where the slip landed, as the grant did", landed);
        emit log_named_uint("comparisons where the slip was refused", refused);
        assertGt(landed, 0);
        assertGt(refused, 0);
    }

    function test_attack_everySignerParentAndKey_aSlipLandsExactlyWhereGrantWould() public {
        _table(false);
    }

    function test_attack_everySignerParentAndKeyInAChildVault_aSlipLandsExactlyWhereGrantWould() public {
        _table(true);
    }
}
