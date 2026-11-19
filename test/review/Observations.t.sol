// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {CrestBase} from "../CrestBase.sol";

/// Review of PR 2 (vault-v01). Behaviour that follows docs/design.md as written but that an owner may not expect.
/// Each test passes on the PR's code and shows what happens today.
contract ReviewObservationsTest is CrestBase {
    uint256 internal subGrant;

    function setUp() public override {
        super.setUp();
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, true));
        vm.prank(buyer);
        subGrant = vault.grant(agentGrant, sub, _wide(), 0);
    }

    /// O1. A stop has no rank: the owner pauses one sub-agent, and the agent above it resumes it. The design allows
    /// it ("a controller above a grant may stop it, resume it"); the owner's only stop that holds is on the agent.
    function test_observe_theAgentLiftsTheOwnersStopOnItsSubAgent() public {
        vm.prank(owner);
        vault.setPaused(subGrant, true);
        vm.prank(buyer);
        vault.setPaused(subGrant, false);
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        assertEq(_grantOf(vault, subGrant).spent, HOLD);
    }

    /// O2. An agent with the right to delegate blocks the owner's chosen successor: it gives that key a grant, and
    /// `acceptOwner` then refuses it for good, since a grant cannot be removed.
    function test_observe_anAgentBlocksTheOwnersSuccessor() public {
        address next = makeAddr("next owner");
        vm.prank(owner);
        vault.proposeOwner(next);
        vm.prank(buyer);
        vault.grant(agentGrant, next, _wide(), 0);
        vm.prank(next);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.acceptOwner();
    }

    /// O3, fixed. Taking away the right to delegate also stops the agent filling an existing child vault.
    function test_attack_mayDelegateOff_stopsFillingAnExistingChild() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0));
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, false));
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.fundChild(address(child), HOLD);
        assertEq(usdc.balanceOf(address(child)), 0);
    }

    /// O4. When the parent vault takes money back, the child's event names the parent vault as `by`, not the key
    /// that asked; the parent emits nothing.
    function test_observe_takeBackRecordsTheParentVaultAsBy() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0));
        vm.prank(buyer);
        vault.fundChild(address(child), HOLD);
        vm.expectEmit(address(child));
        emit ICrestVault.ReturnedToParent(address(vault), HOLD, address(vault));
        vm.prank(owner);
        vault.takeBackFromChild(address(child), HOLD);
    }
}
