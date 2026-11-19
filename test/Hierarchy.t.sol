// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {ICrestVault} from "../src/ICrestVault.sol";
import {CrestBase} from "./CrestBase.sol";

/// Grants inside one vault: an agent gives its sub-agents grants, and no grant can pay past any grant above it.
contract HierarchyTest is CrestBase {
    uint256 internal subGrant;

    function setUp() public override {
        super.setUp();
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, true));
        vm.prank(buyer);
        subGrant = vault.grant(agentGrant, sub, _wide(), 0);
    }

    function test_theAgentGrantsASubAgent_whichFundsInsideTheAgentsLimits() public {
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        assertEq(_grantOf(vault, subGrant).spent, HOLD);
        assertEq(_grantOf(vault, agentGrant).spent, HOLD, "the agent's grant counts its sub-agent's spend");
        assertEq(_grantOf(vault, ROOT).spent, HOLD);
    }

    function test_attack_aWiderSubAgent_isBoundByTheAgentsPerDeal() public {
        H.Terms memory t = _vterms(address(vault), sub);
        t.price = PRICE + 1;
        _expectRefused(t, SUB_PK, abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, agentGrant));
    }

    function test_attack_anUnrestrictedSubAgent_isBoundByTheAgentsMerchants() public {
        H.Terms memory t = _vterms(address(vault), sub);
        t.sellerPayoutAddress = vm.addr(OTHER_PK);
        _expectRefused(t, SUB_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant));
    }

    function test_attack_siblingsTogetherPassTheirParent_refused() public {
        vm.prank(buyer);
        vault.grant(agentGrant, sub2, _wide(), 0);
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        _fundVia(_vterms(address(vault), sub2), SUB2_PK);
        _expectRefused(
            _vterms(address(vault), sub2),
            SUB2_PK,
            abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentGrant)
        );
    }

    function test_attack_pausingTheAgent_stopsItsSubAgents() public {
        vm.prank(owner);
        vault.setPaused(agentGrant, true);
        _expectRefused(
            _vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant)
        );
    }

    function test_theAgentPausesItsSubAgent_andOnlyAuthorityAboveTheSubAgentResumes() public {
        vm.prank(buyer);
        vault.setPaused(subGrant, true);
        _expectRefused(
            _vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.Paused.selector, subGrant)
        );
        vm.prank(sub);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setPaused(subGrant, false);
        vm.prank(buyer);
        vault.setPaused(subGrant, false);
        _fundVia(_vterms(address(vault), sub), SUB_PK);
    }

    function test_attack_aSubAgentWidensOrListsForItself_refused() public {
        bytes32 itself = module.counterpartyOf(sub, adjudicator, fallbackAdj, appealAdj);
        vm.startPrank(sub);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setCaps(subGrant, _wide());
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.allow(agentGrant, itself, true);
        vm.stopPrank();
    }

    function test_attack_anAgentThatMayNotDelegate_cannotGrant() public {
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, false));
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grant(agentGrant, sub2, _wide(), 0);
    }

    function test_attack_oneKeyTwoGrants_refused() public {
        vm.prank(owner);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.grant(ROOT, sub, _wide(), bytes32("other"));
    }

    function test_attack_aZeroPeriod_refused() public {
        ICrestVault.Caps memory c = _wide();
        c.period = 0;
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.InvalidCaps.selector);
        vault.grant(agentGrant, sub2, c, 0);
    }

    function test_theOwnerPausesAndResumesTheRoot() public {
        vm.startPrank(owner);
        vault.setPaused(ROOT, true);
        vault.setPaused(ROOT, false);
        vm.stopPrank();
        _fundVia(_vterms(address(vault), sub), SUB_PK);
    }

    function test_ownershipMovesInTwoSteps_andTheOldOwnerLosesTheRoot() public {
        address next = makeAddr("next owner");
        vm.prank(owner);
        vault.proposeOwner(next);
        vm.prank(stranger);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.acceptOwner();
        vm.prank(next);
        vault.acceptOwner();
        assertEq(vault.owner(), next);
        assertEq(vault.grantOf(next), ROOT);
        vm.prank(owner);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.withdraw(owner, 1);
    }
}
