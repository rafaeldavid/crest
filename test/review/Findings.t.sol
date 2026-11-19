// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {CrestBase} from "../CrestBase.sol";

/// Review of PR 2 (vault-v01). Each test here is an attack the design says must fail. On the PR's code each one
/// FAILS, which is the finding. A fix makes it pass.
contract ReviewFindingsTest is CrestBase {
    CrestVault internal child;
    uint256 internal subInChild;

    function setUp() public override {
        super.setUp();
        vm.prank(buyer);
        child = CrestVault(vault.createChild(agentGrant, 0));
        vm.prank(buyer);
        subInChild = child.grant(ROOT, sub, _wide(), 0);
        vm.prank(buyer);
        vault.fundChild(address(child), 2 * HOLD);
    }

    /// R1. ICrestVault: "A grant's own controller ... can never widen, resume or reopen its own grant." In a child
    /// vault the agent controls the child's root, and `_above` counts it as authority above that root, because the
    /// parent's `authorityOver` includes the parent grant's own controller. So the owner's stop on the child's root
    /// does not hold: the agent lifts it.
    function test_attack_agentResumesTheChildRootTheOwnerPaused_refused() public {
        vm.prank(owner);
        child.setPaused(ROOT, true);
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        child.setPaused(ROOT, false);
    }

    /// R1, the same for limits: the owner narrows the child's root, the agent widens it back.
    function test_attack_agentWidensTheChildRootTheOwnerNarrowed_refused() public {
        vm.prank(owner);
        child.setCaps(ROOT, _caps(1, 1, 1, 1, false, true));
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        child.setCaps(ROOT, _wide());
    }

    /// R1, end to end: after the owner pauses the child's root, a sub-agent in the child still funds a deal once the
    /// agent lifts the owner's stop.
    function test_attack_childPaysAfterTheOwnerPausedItsRoot_refused() public {
        vm.prank(owner);
        child.setPaused(ROOT, true);
        vm.prank(buyer);
        try child.setPaused(ROOT, false) {} catch {}
        _expectRefused(_vterms(address(child), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.Paused.selector, ROOT));
    }

    /// R2. `fundChild` checks the state of this vault's path only, not the ancestor vaults' (`_requireUsable` and
    /// `checkState` exist for that, and `createChild` uses them). After the owner stops the agent in the top vault,
    /// the agent still moves the child's money into a grandchild.
    function test_attack_fundAGrandchildAfterTheTopStopsTheAgent_refused() public {
        vm.prank(buyer);
        CrestVault grandchild = CrestVault(child.createChild(ROOT, 0));
        vm.prank(owner);
        vault.setPaused(agentGrant, true);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant));
        child.fundChild(address(grandchild), HOLD);
    }

    /// R3. A child created under the top vault's root would stay with the previous owner after a handover, so the
    /// root creates no child: the attack cannot start.
    function test_attack_previousOwnerPaysFromARootChildAfterTheHandover_refused() public {
        vm.prank(owner);
        vm.expectRevert(ICrestVault.NoChildFromTheRoot.selector);
        vault.createChild(ROOT, bytes32("root child"));
    }
}
