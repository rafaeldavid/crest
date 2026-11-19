// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC3009Token} from "commerce-payments-test/mocks/MockERC3009Token.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {PayModule} from "../mocks/PayModule.sol";
import {RedTeamBase} from "../redteam/RedTeamBase.sol";

/// The verification of the cross-check's fixes: what close-and-continue lets authority above a key do, whether the
/// stricter delegation rule breaks a path the design needs, and two period changes in a row (V-L1, fixed by counting
/// a window until its end time). Every test here passes and records what the code does.
contract CrossCheckVerifyTest is RedTeamBase {
    uint256 internal subGrant;

    function setUp() public override {
        super.setUp();
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 100, true, true));
        vm.prank(buyer);
        subGrant = vault.grant(agentGrant, sub, _caps(HOLD, 3 * HOLD, type(uint128).max, 100, false, false), 0, "");
    }

    function _delegationOff() internal {
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 100, true, false));
    }

    // The stricter delegation rule

    /// `mayDelegate` false: no one delegates at or below it, except the top vault's principal granting. `createChild` and
    /// `fundChild` give the top principal no exemption (V-L2; whether they should is open for the maintainer).
    function test_observe_theTopPrincipalCannotCreateOrFillAChildBelowAGrantThatMayNotDelegate() public {
        (CrestVault child,) = _agentChild(HOLD);
        _delegationOff();
        vm.startPrank(principal);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.fundChild(address(child), HOLD, "");
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.createChild(agentGrant, bytes32("principal's"), "");
        vm.stopPrank();
    }

    /// Inside a child vault the top principal is not `_isTopPrincipal`, so its grant there walks the path too.
    function test_observe_theTopPrincipalCannotGrantInsideAChildBelowAGrantThatMayNotDelegate() public {
        (CrestVault child,) = _agentChild(HOLD);
        _delegationOff();
        vm.prank(principal);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        child.grant(ROOT, makeAddr("a key the principal adds"), _wide(), bytes32("p"), "");
    }

    /// Everything the principal needs to stop and recover a child still works with delegation off.
    function test_thePrincipalsStopsAndClawbackInsideAChild_stillWork_withDelegationOff() public {
        (CrestVault child, uint256 subInChild) = _agentChild(2 * HOLD);
        _delegationOff();
        ICrestVault.Caps memory narrowed = _caps(HOLD / 2, HOLD, HOLD, 1, true, false);
        vm.startPrank(principal);
        child.setPaused(subInChild, true, "");
        child.setCaps(ROOT, narrowed, "");
        child.allow(ROOT, _merchant(), true, "");
        child.close(subInChild, "");
        child.returnToParent(HOLD, "");
        vault.takeBackFromChild(address(child), HOLD, "");
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(child)), 0, "the principal took every unit back");
    }

    /// Behaviour change since 768cb76: an agent that may delegate no longer creates a child for a sub-agent whose grant
    /// may not; it turns the sub-agent's flag on first. Filling by authority above works once the path may delegate.
    function test_observe_authorityAboveANonDelegatingGrant_turnsItsFlagOnFirst_thenCreatesAndFills() public {
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.createChild(subGrant, 0, "");
        vm.startPrank(buyer);
        vault.setCaps(subGrant, _caps(HOLD, 3 * HOLD, type(uint128).max, 100, false, true), "");
        address child = vault.createChild(subGrant, 0, "");
        vault.fundChild(child, HOLD, "");
        vm.stopPrank();
        assertEq(usdc.balanceOf(child), HOLD);
        assertEq(CrestVault(child).principal(), sub);
    }

    // Close-and-continue

    /// A moved key's open commitments stay on its old path and end there; the new grant starts with nothing open or
    /// spent, and no count underflows.
    function test_aMovedKeysOpenCommitments_endOnTheOldPath() public {
        H.Terms memory t1 = _vterms(address(vault), sub);
        bytes32 id1 = _fundVia(t1, SUB_PK);
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        vm.prank(principal);
        uint256 moved =
            vault.grant(ROOT, sub, _caps(HOLD, 3 * HOLD, type(uint128).max, 100, false, false), bytes32("moved"), "");
        assertTrue(_grantOf(vault, subGrant).closed);
        _release(t1, id1);
        module.close(t1);
        assertEq(_grantOf(vault, subGrant).open, 1, "the old grant still counts the other open deal");
        assertEq(_grantOf(vault, agentGrant).open, 1, "so does the agent's");
        assertEq(_grantOf(vault, ROOT).open, 1);
        assertEq(_grantOf(vault, moved).open, 0);
        assertEq(_grantOf(vault, moved).spent, 0, "the new grant starts fresh");
        assertEq(_grantOf(vault, agentGrant).spent, 2 * HOLD, "the ancestors keep what was spent");
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        assertEq(_grantOf(vault, moved).spent, HOLD);
        assertEq(_grantOf(vault, agentGrant).spent, 2 * HOLD, "the moved key no longer charges the agent");
    }

    /// A key that is a child vault's principal moves: the child, whose parent grant closed, can no longer pay, and its
    /// money comes back by the key itself or by the principal.
    function test_aMovedKeysChildVault_stopsPaying_andItsMoneyComesBack() public {
        vm.prank(buyer);
        vault.setCaps(subGrant, _caps(HOLD, 3 * HOLD, type(uint128).max, 100, false, true), "");
        vm.startPrank(sub);
        CrestVault child = CrestVault(vault.createChild(subGrant, 0, ""));
        vault.fundChild(address(child), 3 * HOLD, "");
        vm.stopPrank();
        _fundVia(_vterms(address(child), sub), SUB_PK);
        vm.prank(principal);
        vault.grant(ROOT, sub, _wide(), bytes32("moved"), "");
        _expectRefused(
            _vterms(address(child), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.GrantClosed.selector, subGrant)
        );
        vm.prank(sub);
        child.returnToParent(HOLD, "");
        vm.prank(principal);
        vault.takeBackFromChild(address(child), HOLD, "");
        assertEq(usdc.balanceOf(address(child)), 0, "every unit left in the child came back");
    }

    /// The agent above the pending principal's key moves it; the handover still lands and closes the moved grant.
    function test_aMovedPendingPrincipal_stillTakesTheRoot() public {
        vm.prank(principal);
        vault.proposePrincipal(sub, "");
        vm.prank(buyer);
        uint256 moved = vault.grant(agentGrant, sub, _wide(), bytes32("moved"), "");
        vm.prank(sub);
        vault.acceptPrincipal("");
        assertEq(vault.principal(), sub);
        assertEq(vault.grantOf(sub), ROOT);
        assertTrue(_grantOf(vault, moved).closed);
    }

    /// Inside a child, its principal's key holds the root, which never moves.
    function test_inAChild_itsPrincipalsKeyNeverMoves() public {
        (CrestVault child,) = _agentChild(HOLD);
        vm.prank(principal);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        child.grant(ROOT, buyer, _wide(), bytes32("move the child's principal"), "");
    }

    /// Info: moving a key to a grant below its own old grant. The path is walked before the old grant closes, so the new
    /// grant is born under a closed grant and can never pay. Closing the key's grant does the same harm, so nothing new
    /// is lost; the key is only parked where those above it can move it again.
    function test_observe_aKeyMovedBelowItsOldGrant_landsInAGrantThatCanNeverPay() public {
        vm.startPrank(buyer);
        vault.setCaps(subGrant, _caps(HOLD, 3 * HOLD, type(uint128).max, 100, false, true), "");
        uint256 below = vault.grant(subGrant, sub2, _wide(), 0, "");
        uint256 moved = vault.grant(below, sub, _wide(), bytes32("down"), "");
        vm.stopPrank();
        assertTrue(_grantOf(vault, subGrant).closed, "the old grant closed");
        assertEq(_grantOf(vault, moved).parent, below);
        assertEq(vault.grantOf(sub), moved);
        _expectRefused(
            _vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.GrantClosed.selector, subGrant)
        );
        vm.prank(principal);
        vault.grant(ROOT, sub, _wide(), bytes32("back up"), "");
        _fundVia(_vterms(address(vault), sub), SUB_PK);
    }

    /// V-L1. Two changes in a row: a daily limit of 3 holds, 3 paid on day 20,717; the next day the principal sets an
    /// hourly limit, then a weekly limit of 4. Zeroing the counter on the first change let the week (index 2,959) take 4
    /// more; counting a window until its end time keeps the 3.
    function test_attack_aShortPeriodBetweenTwoChanges_forgetsTheDaysSpend_refused() public {
        for (uint256 i; i < 3; i++) {
            _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        }
        vm.warp(1_790_064_000); // the start of day 20,718, inside week 2,959 [1,789,603,200; 1,790,208,000)
        ICrestVault.Caps memory hourly = _caps(HOLD, 3 * HOLD, type(uint128).max, 100, true, true);
        hourly.period = 1 hours;
        _setAgentCaps(hourly);
        emit log_named_uint("counted after the hourly change, base units", _grantOf(vault, agentGrant).inPeriod);
        ICrestVault.Caps memory weekly = _caps(HOLD, 4 * HOLD, type(uint128).max, 100, true, true);
        weekly.period = 7 days;
        _setAgentCaps(weekly);
        uint256 more;
        for (uint256 i; i < 4; i++) {
            if (_tryFundVia(_vterms(address(vault), buyer), BUYER_PK)) more++;
        }
        emit log_named_uint("holds paid in the week the principal capped at 4", 3 + more);
        assertLe(3 + more, 4, "the agent paid more in the week than the weekly limit the principal set");
    }

    /// An agent with delegation off cannot move its sub-agent's key: the grant walks its own path first.
    function test_attack_delegationOff_agentMovesItsSubAgentsKey_refused() public {
        _delegationOff();
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grant(agentGrant, sub, _wide(), bytes32("moved"), "");
        assertFalse(_grantOf(vault, subGrant).closed);
    }
}

/// The carry in `setCaps`, fuzzed in a light world (a module that is its own payee): for a single payment, a changed
/// period never undercounts it while it lies in the new current window, after one change or two, and no period or time
/// the types allow makes `setCaps` revert.
contract CrossCheckCarryFuzzTest is Test {
    uint256 internal constant ROOT = 1;
    CrestVault internal vault;
    PayModule internal module;
    MockERC3009Token internal token;
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    uint256 internal g;

    function setUp() public {
        vm.warp(1_790_000_000);
        token = new MockERC3009Token("Mock USDC", "mUSDC", 6);
        CrestFactory factory = new CrestFactory();
        vault = CrestVault(factory.create(principal, address(token), 0));
        module = new PayModule(address(token));
        vm.prank(principal);
        vault.setModule(address(module), address(module), "");
        token.mint(address(vault), 1e30);
    }

    function _caps(uint256 period) internal pure returns (ICrestVault.Caps memory) {
        return ICrestVault.Caps(
            type(uint128).max, type(uint128).max, type(uint128).max, type(uint32).max, uint32(period), 0, false, false
        );
    }

    /// Time is read with the cheatcode: under via-IR a test's own `block.timestamp` can be reused after `vm.warp`.
    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _counted() internal view returns (uint256) {
        ICrestVault.Grant memory x = vault.getGrant(g);
        return x.windowEnd > (_now() / x.caps.period) * x.caps.period ? x.inPeriod : 0;
    }

    /// One change: the last payment is never undercounted while it lies in the new current window.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_oneChange_neverUndercountsTheLastPaymentInTheNewWindow(
        uint32 p1,
        uint32 p2,
        uint32 spendAt,
        uint32 change
    ) public {
        p1 = uint32(bound(p1, 1, 400 days));
        p2 = uint32(bound(p2, 1, 400 days));
        vm.prank(principal);
        g = vault.grant(ROOT, agent, _caps(p1), 0, "");
        vm.warp(_now() + bound(spendAt, 0, 400 days));
        uint256 t0 = _now();
        module.pay(vault, agent, 100, bytes32(0));
        vm.warp(_now() + bound(change, 0, 800 days));
        vm.prank(principal);
        vault.setCaps(g, _caps(p2), "");
        if (t0 >= (_now() / p2) * p2) assertGe(_counted(), 100, "undercount after one change");
    }

    /// Two changes with no payment between (V-L1): the first change must not lose the counter.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_twoChanges_neverUndercountTheLastPaymentInTheNewWindow(
        uint32 p1,
        uint32 p2,
        uint32 p3,
        uint32 spendAt,
        uint32 firstChange,
        uint32 secondChange
    ) public {
        p1 = uint32(bound(p1, 1, 400 days));
        p2 = uint32(bound(p2, 1, 400 days));
        p3 = uint32(bound(p3, 1, 400 days));
        vm.prank(principal);
        g = vault.grant(ROOT, agent, _caps(p1), 0, "");
        vm.warp(_now() + bound(spendAt, 0, 400 days));
        uint256 t0 = _now();
        module.pay(vault, agent, 100, bytes32(0));
        vm.warp(_now() + bound(firstChange, 0, 800 days));
        vm.prank(principal);
        vault.setCaps(g, _caps(p2), "");
        if (t0 >= (_now() / p2) * p2) assertGe(_counted(), 100, "undercount after one change");
        vm.warp(_now() + bound(secondChange, 0, 800 days));
        vm.prank(principal);
        vault.setCaps(g, _caps(p3), "");
        if (t0 >= (_now() / p3) * p3) assertGe(_counted(), 100, "undercount after two changes");
    }

    /// Measures whether this build reuses a test's `block.timestamp` after `vm.warp`.
    function test_observe_aTestsBlockTimestampAfterAWarp() public {
        uint256 before = block.timestamp;
        vm.warp(before + 1 days);
        emit log_named_uint("block.timestamp after a 1-day warp, minus before, in s", block.timestamp - before);
        emit log_named_uint("vm.getBlockTimestamp after the warp, minus before, in s", vm.getBlockTimestamp() - before);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_setCapsNeverOverflows(uint32 p1, uint32 p2, uint40 at) public {
        p1 = uint32(bound(p1, 1, type(uint32).max));
        p2 = uint32(bound(p2, 1, type(uint32).max));
        vm.prank(principal);
        g = vault.grant(ROOT, agent, _caps(p1), 0, "");
        vm.warp(bound(at, _now(), type(uint40).max - 2 hours));
        module.pay(vault, agent, 100, bytes32(0));
        vm.prank(principal);
        vault.setCaps(g, _caps(p2), "");
        module.pay(vault, agent, 100, bytes32(0));
        assertGe(vault.getGrant(g).spent, 200);
    }
}
