// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../src/CrestVault.sol";
import {ICrestFactory} from "../src/ICrestFactory.sol";
import {ICrestVault} from "../src/ICrestVault.sol";
import {CrestBase} from "./CrestBase.sol";

/// Child vaults: an agent creates its sub-agent's own vault, fills it inside its own limits, and the child's payments
/// still answer to everything above it.
contract ChildVaultTest is CrestBase {
    CrestVault internal child;
    uint256 internal subInChild;

    function setUp() public override {
        super.setUp();
        vm.prank(buyer);
        child = CrestVault(vault.createChild(agentGrant, 0));
        vm.prank(buyer); // the agent owns the child and controls its root
        subInChild = child.grant(ROOT, sub, _wide(), 0);
    }

    function test_theChildIsTheAgents_underTheAgentsGrant() public view {
        assertEq(child.owner(), buyer);
        assertEq(child.parent(), address(vault));
        assertEq(child.parentGrant(), agentGrant);
        assertEq(vault.grantOfChild(address(child)), agentGrant);
        assertEq(child.payeeOf(address(module)), module.payee(), "the child inherits the top vault's modules");
        assertEq(address(child), factory.childAddressOf(address(vault), buyer, agentGrant, 0));
    }

    function test_fillingTheChild_countsAgainstTheAgentsDay() public {
        vm.prank(buyer);
        vault.fundChild(address(child), 2 * HOLD);
        assertEq(usdc.balanceOf(address(child)), 2 * HOLD);
        assertEq(_grantOf(vault, agentGrant).inPeriod, 2 * HOLD);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentGrant));
        vault.fundChild(address(child), 2 * HOLD);
    }

    function test_theSubAgentPaysADealFromTheChild_endsReleased() public {
        vm.prank(buyer);
        vault.fundChild(address(child), 2 * HOLD);
        H.Terms memory t = _vterms(address(child), sub);
        bytes32 id = _fundVia(t, SUB_PK);
        assertEq(usdc.balanceOf(address(child)), HOLD);
        _release(t, id);
        module.close(t);
        assertEq(_grantOf(child, subInChild).open, 0);
    }

    function test_attack_childPaymentOverTheParentsPerDeal_refused() public {
        vm.prank(buyer);
        vault.fundChild(address(child), 3 * HOLD);
        H.Terms memory t = _vterms(address(child), sub);
        t.price = PRICE + 1;
        _expectRefused(t, SUB_PK, abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, agentGrant));
    }

    function test_attack_childPaysAMerchantTheParentDidNotList_refused() public {
        vm.prank(buyer);
        vault.fundChild(address(child), 2 * HOLD);
        H.Terms memory t = _vterms(address(child), sub);
        t.sellerPayoutAddress = vm.addr(OTHER_PK);
        _expectRefused(t, SUB_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant));
    }

    function test_attack_childAfterTheOwnerPausesTheAgent_refused() public {
        vm.prank(buyer);
        vault.fundChild(address(child), 2 * HOLD);
        vm.prank(owner);
        vault.setPaused(agentGrant, true);
        _expectRefused(_vterms(address(child), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant));
    }

    function test_attack_childEnablesItsOwnModuleOrWithdraws_refused() public {
        vm.prank(buyer);
        vault.fundChild(address(child), HOLD);
        vm.startPrank(buyer);
        vm.expectRevert(ICrestVault.NotTopVault.selector);
        child.setModule(address(this), buyer);
        vm.expectRevert(ICrestVault.NotTopVault.selector);
        child.withdraw(buyer, HOLD);
        vm.stopPrank();
    }

    function test_moneyGoesBackUpOnly_byTheAgentOrTheOwner() public {
        vm.prank(buyer);
        vault.fundChild(address(child), 2 * HOLD);
        vm.prank(buyer);
        child.returnToParent(HOLD);
        assertEq(usdc.balanceOf(address(child)), HOLD);
        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(owner);
        vault.takeBackFromChild(address(child), HOLD);
        assertEq(usdc.balanceOf(address(child)), 0);
        assertEq(usdc.balanceOf(address(vault)) - before, HOLD, "the owner took the child's money back");
    }

    function test_theOwnerReachesTheChildDirectly() public {
        vm.prank(buyer);
        vault.fundChild(address(child), HOLD);
        vm.prank(owner);
        child.returnToParent(HOLD);
        vm.prank(owner);
        child.setPaused(subInChild, true);
        assertTrue(_grantOf(child, subInChild).paused);
    }

    function test_attack_strangerFillsOrEmptiesTheChild_refused() public {
        vm.prank(buyer);
        vault.fundChild(address(child), HOLD);
        vm.startPrank(stranger);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.fundChild(address(child), HOLD);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.takeBackFromChild(address(child), HOLD);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        child.returnToParent(HOLD);
        vm.stopPrank();
    }

    function test_attack_theSubAgentEmptiesItsChild_refused() public {
        vm.prank(buyer);
        vault.fundChild(address(child), HOLD);
        vm.prank(sub);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        child.returnToParent(HOLD);
        vm.prank(sub);
        vm.expectRevert(ICrestVault.NotTopVault.selector);
        child.withdraw(sub, HOLD);
    }

    function test_attack_aChildMadeOutsideAVault_refused() public {
        vm.prank(stranger);
        vm.expectRevert(ICrestFactory.NotAVault.selector);
        factory.createChild(stranger, agentGrant, 0);
    }

    function test_attack_anUnknownChild_refused() public {
        vm.prank(owner);
        vm.expectRevert(ICrestVault.UnknownChild.selector);
        vault.fundChild(stranger, HOLD);
    }

    function test_attack_aPausedAgentCannotCreateAChild() public {
        vm.prank(owner);
        vault.setPaused(agentGrant, true);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant));
        vault.createChild(agentGrant, bytes32("second"));
    }

    function test_aGrandchildIsBoundByTheTop() public {
        vm.prank(buyer);
        vault.fundChild(address(child), 3 * HOLD);
        vm.prank(buyer);
        CrestVault grandchild = CrestVault(child.createChild(ROOT, 0));
        vm.prank(buyer);
        child.fundChild(address(grandchild), 2 * HOLD);
        vm.prank(buyer);
        grandchild.grant(ROOT, sub2, _wide(), 0);
        H.Terms memory t = _vterms(address(grandchild), sub2);
        t.price = PRICE + 1;
        _expectRefused(t, SUB2_PK, abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, agentGrant));
        H.Terms memory ok = _vterms(address(grandchild), sub2);
        bytes32 id = _fundVia(ok, SUB2_PK);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
    }
}
