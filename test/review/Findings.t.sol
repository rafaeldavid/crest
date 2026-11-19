// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {CrestBase} from "../CrestBase.sol";

/// Review of PR 2 (vault-v01). Each test here is an attack the design says must fail. Each one failed on the code
/// the review read, which was the finding; each passes since its fix.
contract ReviewFindingsTest is CrestBase {
    CrestVault internal child;
    uint256 internal subInChild;

    function setUp() public override {
        super.setUp();
        vm.prank(buyer);
        child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vm.prank(buyer);
        subInChild = child.grant(ROOT, sub, _wide(), 0, "");
        vm.prank(buyer);
        vault.fundChild(address(child), 2 * HOLD, "");
    }

    /// R1. ICrestVault: "A grant's own controller ... can never widen, resume or reopen its own grant." In a child
    /// vault the agent controls the child's root, and `_above` counts it as authority above that root, because the
    /// parent's `authorityOver` includes the parent grant's own controller. So the principal's stop on the child's root
    /// does not hold: the agent lifts it.
    function test_attack_agentResumesTheChildRootThePrincipalPaused_refused() public {
        vm.prank(principal);
        child.setPaused(ROOT, true, "");
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        child.setPaused(ROOT, false, "");
    }

    /// R1, the same for limits: the principal narrows the child's root, the agent widens it back.
    function test_attack_agentWidensTheChildRootThePrincipalNarrowed_refused() public {
        vm.prank(principal);
        child.setCaps(ROOT, _caps(1, 1, 1, 1, false, true), "");
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        child.setCaps(ROOT, _wide(), "");
    }

    /// R1, end to end: after the principal pauses the child's root, a sub-agent in the child still funds a deal once the
    /// agent lifts the principal's stop.
    function test_attack_childPaysAfterThePrincipalPausedItsRoot_refused() public {
        vm.prank(principal);
        child.setPaused(ROOT, true, "");
        vm.prank(buyer);
        try child.setPaused(ROOT, false, "") {} catch {}
        _expectRefused(_vterms(address(child), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.Paused.selector, ROOT));
    }

    /// R2. `fundChild` checks the state of this vault's path only, not the ancestor vaults' (`_requireDelegable` and
    /// `checkDelegable` exist for that, and `createChild` uses them). After the principal stops the agent in the top vault,
    /// the agent still moves the child's money into a grandchild.
    function test_attack_fundAGrandchildAfterTheTopStopsTheAgent_refused() public {
        vm.prank(buyer);
        CrestVault grandchild = CrestVault(child.createChild(ROOT, 0, ""));
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant));
        child.fundChild(address(grandchild), HOLD, "");
    }

    /// R3. A child created under the top vault's root would stay with the previous principal after a handover, so the
    /// root creates no child: the attack cannot start.
    function test_attack_previousPrincipalPaysFromARootChildAfterTheHandover_refused() public {
        vm.prank(principal);
        vm.expectRevert(ICrestVault.NoChildFromTheRoot.selector);
        vault.createChild(ROOT, bytes32("root child"), "");
    }
}
