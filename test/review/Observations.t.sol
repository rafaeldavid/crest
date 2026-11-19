// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {CrestBase} from "../CrestBase.sol";

/// Review of PR 2 (vault-v01). Behaviour that follows docs/design.md as written but that a principal may not expect.
/// Each test passes on the PR's code and shows what happens today.
contract ReviewObservationsTest is CrestBase {
    uint256 internal subGrant;

    function setUp() public override {
        super.setUp();
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, true));
        vm.prank(buyer);
        subGrant = vault.grant(agentGrant, sub, _wide(), 0, "");
    }

    /// O1. A stop has no rank: the principal pauses one sub-agent, and the agent above it resumes it. The design allows
    /// it ("a controller above a grant may stop it, resume it"); the principal's only stop that holds is on the agent.
    function test_observe_theAgentLiftsThePrincipalsStopOnItsSubAgent() public {
        vm.prank(principal);
        vault.setPaused(subGrant, true, "");
        vm.prank(buyer);
        vault.setPaused(subGrant, false, "");
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        assertEq(_grantOf(vault, subGrant).spent, HOLD);
    }

    /// O2, fixed. An agent that gives the principal's chosen successor a grant first does not block the handover:
    /// accepting closes that grant and moves the key to the root.
    function test_attack_anAgentBlocksThePrincipalsSuccessor_refused() public {
        address next = makeAddr("next principal");
        vm.prank(principal);
        vault.proposePrincipal(next, "rotating the principal key");
        vm.prank(buyer);
        uint256 squat = vault.grant(agentGrant, next, _wide(), 0, "");
        vm.prank(next);
        vault.acceptPrincipal("");
        assertEq(vault.principal(), next);
        assertEq(vault.grantOf(next), ROOT);
        assertTrue(vault.getGrant(squat).closed, "the squatted grant is closed");
    }

    /// O3, fixed. Taking away the right to delegate also stops the agent filling an existing child vault.
    function test_attack_mayDelegateOff_stopsFillingAnExistingChild() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, false));
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.fundChild(address(child), HOLD, "");
        assertEq(usdc.balanceOf(address(child)), 0);
    }

    /// O4. When the parent vault takes money back, the child's event names the parent vault as `by`; the parent's own
    /// `ChildTakenBack` names the key that asked.
    function test_observe_takeBackRecordsTheParentVaultAsBy() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vm.prank(buyer);
        vault.fundChild(address(child), HOLD, "");
        vm.expectEmit(address(child));
        emit ICrestVault.ReturnedToParent(address(vault), HOLD, address(vault), "");
        vm.prank(principal);
        vault.takeBackFromChild(address(child), HOLD, "");
    }
}
