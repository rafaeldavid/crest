// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {CrestBase} from "../CrestBase.sol";

/// Re-review of PR 2 at a206ff3: what the code does at each edge the fixes touched. Each `test_observe_*` records
/// behaviour as designed; each `test_attack_*` passes when the defence holds.
contract ReviewRereviewTest is CrestBase {
    uint256 internal subGrant;

    function setUp() public override {
        super.setUp();
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, true));
        vm.prank(buyer);
        subGrant = vault.grant(agentGrant, sub, _wide(), 0, "");
    }

    /// N1. A handover to the current principal must not close the root. At a206ff3 `acceptPrincipal` closed the grant
    /// the proposed key held, which for the current principal is the root, and every payment stopped for good.
    function test_attack_aSelfHandoverClosesTheRoot_refused() public {
        vm.prank(principal);
        vault.proposePrincipal(principal, "");
        vm.prank(principal);
        vault.acceptPrincipal("");
        assertFalse(vault.getGrant(ROOT).closed, "a self-handover closed the root for good");
        assertEq(vault.principal(), principal);
        assertEq(vault.grantOf(principal), ROOT);
        bytes32 id = _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
    }

    /// N2. Closing frees the key, so a principal's close of a sub-agent is undone by the agent above it: the agent
    /// grants the same key again, and the sub-agent pays. The grant stays closed; the key does not.
    function test_observe_theAgentRegrantsTheKeyOfASubAgentThePrincipalClosed() public {
        vm.prank(principal);
        vault.close(subGrant, "stop this sub-agent");
        vm.prank(buyer);
        uint256 again = vault.grant(agentGrant, sub, _wide(), bytes32("again"), "");
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        assertEq(_grantOf(vault, again).spent, HOLD);
        assertTrue(_grantOf(vault, subGrant).closed);
    }

    /// N3. An agreement the key signed before its grant was closed funds under the key's next grant: the vault finds the
    /// grant by the key at funding time.
    function test_observe_aSignatureFromBeforeTheCloseFundsUnderTheNextGrant() public {
        H.Terms memory t = _vterms(address(vault), sub);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, SUB_PK);
        vm.prank(principal);
        vault.close(subGrant, "");
        vm.prank(principal);
        uint256 next = vault.grant(ROOT, sub, _wide(), bytes32("next"), "");
        bytes32 id = module.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)}));
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
        assertEq(_grantOf(vault, next).spent, HOLD, "charged to the new grant, under the root");
    }

    /// N4. Turning off the parent grant's right to delegate stopped fills, but not grants inside an existing child. Since
    /// the cross-check's X-M1 fix, delegating asks every grant on the path, ancestor vaults included, so it stops both.
    /// The agent still cannot widen the child's root.
    function test_attack_mayDelegateOffAtTheParent_stillGrantsInsideTheChild_refused() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, false));
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        child.grant(ROOT, sub2, _wide(), 0, "");
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        child.setCaps(ROOT, _wide(), "");
    }

    /// N5. After the principal closes the agent's grant, the agent still manages the grants inside its child through
    /// the child's open root, against "a closed grant's controller has no authority". Payments from the child stay
    /// refused, so the authority moves no money.
    function test_observe_aClosedAgentStillManagesGrantsInsideItsChild_butTheChildCannotPay() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vm.prank(buyer);
        vault.fundChild(address(child), HOLD, "");
        vm.prank(buyer);
        uint256 inChild = child.grant(ROOT, sub2, _wide(), 0, "");
        vm.prank(principal);
        vault.close(agentGrant, "");
        vm.prank(buyer);
        child.setPaused(inChild, true, "");
        vm.prank(buyer);
        child.setPaused(inChild, false, "");
        _expectRefused(
            _vterms(address(child), sub2), SUB2_PK, abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant)
        );
    }

    /// The R1 fix holds one level further down: a grandchild's root cannot be resumed by the agent that is principal of
    /// both the child and the grandchild.
    function test_attack_agentResumesAGrandchildRootThePrincipalPaused_refused() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vm.prank(buyer);
        CrestVault grandchild = CrestVault(child.createChild(ROOT, 0, ""));
        vm.prank(principal);
        grandchild.setPaused(ROOT, true, "");
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        grandchild.setPaused(ROOT, false, "");
    }

    /// The open-path rule for delegating (`grant`'s `_requireUsable`, design section 2). No other test fails without
    /// it: the red team's closed-agent test is already refused by the closed-controller rule in `_above`. Here the
    /// sub-agent grants on its own authority, under an agent the principal paused, and then under one it closed.
    function test_attack_aSubAgentGrantsUnderAStoppedAgent_refused() public {
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "");
        vm.prank(sub);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant));
        vault.grant(subGrant, stranger, _wide(), 0, "");
        vm.prank(principal);
        vault.close(agentGrant, "");
        vm.prank(sub);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant));
        vault.grant(subGrant, stranger, _wide(), 0, "");
    }

    /// The closed-controller rule in `_above` (ICrestVault: "a closed grant's controller has no authority"). No other
    /// test fails without it: the red team's closed-agent test is already refused by the open-path rule in `grant`.
    function test_attack_aClosedAgentManagesItsSubAgent_refused() public {
        vm.prank(principal);
        vault.close(agentGrant, "");
        vm.startPrank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setCaps(subGrant, _wide(), "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.allow(subGrant, keccak256("anyone"), true, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.close(subGrant, "");
        vm.stopPrank();
    }

    /// The period change keeps the window's spend in both directions: shorter and longer.
    function test_attack_aPeriodChangeOpensAFreshWindow_refused() public {
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        ICrestVault.Caps memory c = _caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, true);
        c.period = 1 hours;
        _setAgentCaps(c);
        _expectRefused(
            _vterms(address(vault), buyer),
            BUYER_PK,
            abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentGrant)
        );
        c.period = 7 days;
        _setAgentCaps(c);
        _expectRefused(
            _vterms(address(vault), buyer),
            BUYER_PK,
            abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentGrant)
        );
    }
}
