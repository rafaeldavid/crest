// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {RedTeamBase} from "../redteam/RedTeamBase.sol";

/// The cross-check against published audits of capped spenders, role trees, allowance modules and periodic spend
/// permissions found three gaps: delegation turned off did not stop delegating through a sub-agent (X-M1), a longer
/// period forgot spend inside the new window (X-L1), and an agent could take a key before the principal granted it
/// (X-L2). Each `test_attack_*` failed on the code the cross-check read and passes since its fix.
contract CrossCheckGapsTest is RedTeamBase {
    uint256 internal subGrant;

    function setUp() public override {
        super.setUp();
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 100, true, true));
        vm.prank(buyer);
        // The sub-agent may not delegate.
        subGrant = vault.grant(
            agentGrant, sub, _caps(HOLD, 3 * HOLD, type(uint128).max, 100, false, false), 0, "first sub-agent"
        );
    }

    // X-M1. Delegation turned off on the agent's grant: no one but the top principal grants, creates or fills a child
    // vault at or below it, so the agent cannot delegate through its existing sub-agent.

    function _delegationOff() internal {
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 100, true, false));
    }

    function test_attack_delegationOff_agentStillGrantsANewKeyThroughItsSubAgent_refused() public {
        _delegationOff();
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grant(subGrant, sub2, _wide(), 0, "a key added after delegation was turned off");
    }

    function test_attack_delegationOff_agentStillCreatesAndFillsAChildThroughItsSubAgent_refused() public {
        vm.prank(principal);
        vault.setCaps(subGrant, _caps(HOLD, 3 * HOLD, type(uint128).max, 100, false, true), "");
        vm.prank(buyer);
        address child = vault.createChild(subGrant, bytes32("before off"), "");
        _delegationOff();
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.createChild(subGrant, bytes32("after off"), "");
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.fundChild(child, 2 * HOLD, "");
        assertEq(usdc.balanceOf(child), 0);
        assertEq(_grantOf(vault, agentGrant).inPeriod, 0);
    }

    /// The second route: the agent, still above its sub-agent, turns the sub-agent's own delegation on, and the
    /// sub-agent adds a key. The agent's grant on the path still says no.
    function test_attack_delegationOff_agentTurnsItOnForItsSubAgent_whichAddsTheKey_refused() public {
        _delegationOff();
        vm.prank(buyer);
        vault.setCaps(subGrant, _caps(HOLD, 3 * HOLD, type(uint128).max, 100, false, true), "");
        vm.prank(sub);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grant(subGrant, sub2, _wide(), 0, "");
    }

    /// Inside a child vault the agent made, its delegation turned off in the parent stops grants and grandchildren.
    function test_attack_delegationOffAtTheParent_agentStillGrantsInsideItsChild_refused() public {
        (CrestVault child,) = _agentChild(2 * HOLD);
        _delegationOff();
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        child.grant(ROOT, makeAddr("a key in the child"), _wide(), bytes32("after off"), "");
    }

    function test_theTopPrincipalStillGrantsBelowAGrantThatMayNotDelegate() public {
        _delegationOff();
        vm.prank(principal);
        uint256 id = vault.grant(subGrant, sub2, _wide(), 0, "the principal's own choice");
        assertEq(vault.grantOf(sub2), id);
    }

    // X-L1. A longer period keeps the spend of the last window paid in when that window falls inside the new one.

    function test_attack_lengthenThePeriodTheDayAfter_agentPassesTheNewWeeklyLimit_refused() public {
        uint256 week = vm.getBlockTimestamp() / 7 days;
        for (uint256 i; i < 3; i++) {
            _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        }
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days); // the next day, the same week
        assertEq(vm.getBlockTimestamp() / 7 days, week, "the same week");

        ICrestVault.Caps memory weekly = _caps(HOLD, 4 * HOLD, type(uint128).max, 100, true, true);
        weekly.period = 7 days;
        _setAgentCaps(weekly); // the principal means: at most 4 holds this week

        uint256 more;
        for (uint256 i; i < 4; i++) {
            if (_tryFundVia(_vterms(address(vault), buyer), BUYER_PK)) more++;
        }
        assertEq(3 + more, 4, "the week holds exactly the 4 holds the principal set");
    }

    /// Open, for the maintainer: the vault keeps one window's counter, not a history, so a longer period knows only the
    /// last window paid in. After 3 holds on each of two days, a weekly limit of 6 counts the second day's 3 and lets 3
    /// more through: 9 in the week. To bound it, set a lower limit for the rest of the week or pause first.
    function test_observe_lengthenThePeriodAfterTwoDaysOfSpend_countsOnlyTheLastDay() public {
        for (uint256 i; i < 3; i++) {
            _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        }
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        for (uint256 i; i < 3; i++) {
            _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        }
        ICrestVault.Caps memory weekly = _caps(HOLD, 6 * HOLD, type(uint128).max, 100, true, true);
        weekly.period = 7 days;
        _setAgentCaps(weekly);
        assertEq(_grantOf(vault, agentGrant).inPeriod, 3 * HOLD, "the new week starts from the last day's spend");
        uint256 more;
        for (uint256 i; i < 4; i++) {
            if (_tryFundVia(_vterms(address(vault), buyer), BUYER_PK)) more++;
        }
        assertEq(6 + more, 9);
    }

    function test_shortenThePeriod_keepsTheCurrentWindowsSpend() public {
        for (uint256 i; i < 3; i++) {
            _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        }
        ICrestVault.Caps memory hourly = _caps(HOLD, 3 * HOLD, type(uint128).max, 100, true, true);
        hourly.period = 1 hours;
        _setAgentCaps(hourly);
        assertEq(_grantOf(vault, agentGrant).inPeriod, 3 * HOLD);
        assertFalse(_tryFundVia(_vterms(address(vault), buyer), BUYER_PK));
    }

    // X-L2. A key that holds a grant moves when someone above that grant grants it: the old grant closes in the same
    // transaction, as `acceptPrincipal` does, so an agent cannot hold a key the principal is granting.

    function test_attack_agentTakesTheKeyThePrincipalIsGranting_principalsGrantRefused() public {
        vm.prank(buyer);
        uint256 squat = vault.grant(agentGrant, sub2, _wide(), bytes32("squat"), "");
        ICrestVault.Caps memory own = _caps(2 * HOLD, 6 * HOLD, type(uint128).max, 4, false, false);
        vm.expectEmit(address(vault));
        emit ICrestVault.Closed(squat, principal, "a new agent of my own");
        vm.prank(principal);
        uint256 id = vault.grant(ROOT, sub2, own, 0, "a new agent of my own");
        assertEq(vault.grantOf(sub2), id);
        assertEq(_grantOf(vault, id).parent, ROOT);
        assertTrue(_grantOf(vault, squat).closed);
    }

    function test_attack_agentRetakesTheKeyAfterThePrincipalClosesTheSquat_principalsGrantRefused() public {
        vm.prank(buyer);
        uint256 squat = vault.grant(agentGrant, sub2, _wide(), bytes32("squat"), "");
        vm.prank(principal);
        vault.close(squat, "free the key");
        vm.prank(buyer);
        vault.grant(agentGrant, sub2, _wide(), bytes32("squat again"), "");
        vm.prank(principal);
        uint256 id = vault.grant(ROOT, sub2, _wide(), 0, "");
        assertEq(vault.grantOf(sub2), id);
    }

    /// Only authority above the key's grant moves it: an agent in another branch cannot take a key held here.
    function test_attack_anAgentTakesAKeyHeldInAnotherBranch_refused() public {
        address other = makeAddr("another agent");
        vm.prank(principal);
        uint256 otherGrant = vault.grant(ROOT, other, _wide(), bytes32("other"), "");
        vm.prank(other);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.grant(otherGrant, sub, _wide(), 0, "");
        assertEq(vault.grantOf(sub), subGrant);
    }

    /// The principal's own key holds the root, which never moves.
    function test_attack_grantThePrincipalsOwnKey_refused() public {
        vm.prank(principal);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.grant(ROOT, principal, _wide(), 0, "");
        assertFalse(_grantOf(vault, ROOT).closed);
    }
}
