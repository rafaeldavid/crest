// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {LibClone} from "solady/utils/LibClone.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {RedTeamBase} from "./RedTeamBase.sol";

/// Red team: the grant tree, child vaults, the principal role and the factory.
///
/// Every `test_attack_*` passes when the defence holds and fails when the attack works. A test that fails today says
/// so in its description, with the line in `src/` that lets it through.
contract RedTeamTreeTest is RedTeamBase {
    // Child vaults: the agent against the principal's controls on its child

    /// The principal pauses the agent's child vault at its root, to stop the sub-agent and leave the agent running. The
    /// agent controls that root as the child's principal, and the interface says a controller "can never widen, resume or
    /// reopen its own grant".
    /// Fails today: in the child, `_above` (`CrestVault.sol:323`) asks the parent `authorityOver(agent, agentGrant)`,
    /// which is true for the parent grant's own controller, so the agent counts as above its own child root.
    function test_attack_agentResumesItsChildVaultAfterThePrincipalPausedIt_refused() public {
        (CrestVault child,) = _agentChild(2 * HOLD);
        vm.prank(principal);
        child.setPaused(ROOT, true, "");

        vm.prank(buyer);
        try child.setPaused(ROOT, false, "") {} catch {}
        bool paid = _tryFundVia(_vterms(address(child), sub), SUB_PK);

        assertFalse(paid, "the child paid after the principal paused it");
        assertTrue(_grantOf(child, ROOT).paused, "the agent lifted the principal's pause on its own child vault");
    }

    /// The principal narrows the agent's child vault at its root to half a hold per deal. The agent widens it back and its
    /// sub-agent pays a whole hold from the child. Fails today, for the same reason as the test above.
    function test_attack_agentWidensItsChildVaultPastThePrincipalsLimit_refused() public {
        (CrestVault child,) = _agentChild(2 * HOLD);
        ICrestVault.Caps memory tight =
            _caps(HOLD / 2, type(uint128).max, type(uint128).max, type(uint32).max, false, true);
        vm.prank(principal);
        child.setCaps(ROOT, tight, "");

        vm.prank(buyer);
        try child.setCaps(ROOT, _wide(), "") {} catch {}
        bool paid = _tryFundVia(_vterms(address(child), sub), SUB_PK);

        assertFalse(paid, "the child paid past the per-deal limit the principal set on it");
        assertEq(_grantOf(child, ROOT).caps.perSpend, HOLD / 2, "the agent widened its own child root");
    }

    /// The principal closes the agent. The agent then moves the money in its child vault down into a grandchild, further
    /// from the principal. Fails today: `fundChild` (`CrestVault.sol:177-187`) checks only the paying vault's own path and
    /// not its parent vaults' state, as `createChild` does through `_requireUsable`.
    function test_attack_agentMovesMoneyDownItsTreeAfterThePrincipalClosedIt_refused() public {
        (CrestVault child,) = _agentChild(3 * HOLD);
        vm.prank(buyer);
        CrestVault grandchild = CrestVault(child.createChild(ROOT, 0, ""));
        vm.prank(principal);
        vault.close(agentGrant, "");

        vm.prank(buyer);
        try child.fundChild(address(grandchild), 3 * HOLD, "") {} catch {}

        assertEq(usdc.balanceOf(address(grandchild)), 0, "a closed agent moved money down its tree");
    }

    /// After the principal closes the agent, the grandchild's payments are still refused from the top, and the principal
    /// reaches the grandchild's money directly. So the test above costs the principal steps, not money.
    function test_attack_grandchildPaysAfterThePrincipalClosedTheAgent_refused() public {
        (CrestVault child,) = _agentChild(3 * HOLD);
        vm.startPrank(buyer);
        CrestVault grandchild = CrestVault(child.createChild(ROOT, 0, ""));
        child.fundChild(address(grandchild), 2 * HOLD, "");
        grandchild.grant(ROOT, sub2, _wide(), 0, "");
        vm.stopPrank();
        vm.prank(principal);
        vault.close(agentGrant, "");

        assertFalse(_tryFundVia(_vterms(address(grandchild), sub2), SUB2_PK), "the grandchild paid");
        vm.prank(principal);
        grandchild.returnToParent(2 * HOLD, "");
        vm.prank(principal);
        vault.takeBackFromChild(address(child), 3 * HOLD, "");
        assertEq(usdc.balanceOf(address(vault)), 1_000 * HOLD, "every unit came back to the top");
    }

    /// The agent hands its child vault to another key. At `8c81641` a child vault refuses any handover (`NotTopVault`);
    /// at `2b41c01` the handover landed, and the new key had to gain no authority above the child and no way to pay
    /// past the agent's grant. The test holds on both.
    function test_attack_childPrincipalHandsTheChildToAnotherKey_whichGainsNothingAbove() public {
        (CrestVault child,) = _agentChild(2 * HOLD);
        vm.prank(buyer);
        try child.proposePrincipal(sub2, "") {}
        catch {
            assertEq(child.principal(), buyer, "a refused handover changed nothing");
            return;
        }
        vm.prank(sub2);
        child.acceptPrincipal("");

        bytes32 itself = module.counterpartyOf(sub2, adjudicator, fallbackAdj, appealAdj);
        address newKey = makeAddr("new key");
        vm.startPrank(sub2);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.fundChild(address(child), HOLD, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setCaps(agentGrant, _wide(), "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.allow(agentGrant, itself, true, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grant(agentGrant, newKey, _wide(), 0, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        child.setCaps(ROOT, _wide(), "");
        vm.expectRevert(ICrestVault.NotTopVault.selector);
        child.withdraw(sub2, HOLD, "");
        vm.stopPrank();

        H.Terms memory t = _vterms(address(child), sub2);
        t.sellerPayoutAddress = vm.addr(OTHER_PK);
        _expectRefused(t, SUB2_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant));
    }

    /// Money between two of the agent's children: no direct path, and the way up and back down is charged to the
    /// agent's day again.
    function test_attack_agentMovesMoneySidewaysBetweenItsChildrenWithoutACharge_refused() public {
        (CrestVault one,) = _agentChild(2 * HOLD);
        vm.prank(buyer);
        CrestVault two = CrestVault(vault.createChild(agentGrant, bytes32("two"), ""));

        vm.startPrank(buyer);
        vm.expectRevert(ICrestVault.UnknownChild.selector);
        one.fundChild(address(two), HOLD, "");
        vm.expectRevert(ICrestVault.UnknownChild.selector);
        two.takeBackFromChild(address(one), HOLD, "");
        one.returnToParent(2 * HOLD, "");
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentGrant));
        vault.fundChild(address(two), 2 * HOLD, "");
        vm.stopPrank();
    }

    // Handover

    /// The principal proposes a new key. The agent, which may delegate, sees the proposal and gives that key a grant of its
    /// own first. Fails today: `acceptPrincipal` refuses a key that holds any grant (`CrestVault.sol:81`), any controller
    /// that may delegate can give any free key a grant (`CrestVault.sol:120`), and no function ever frees a key's slot.
    function test_attack_agentTakesTheProposedPrincipalsKeySlot_blocksTheHandover() public {
        address next = makeAddr("next principal");
        vm.prank(principal);
        vault.proposePrincipal(next, "");

        vm.prank(buyer);
        try vault.grant(agentGrant, next, _wide(), bytes32("squat"), "") {} catch {}
        vm.prank(next);
        try vault.acceptPrincipal("") {} catch {}

        assertEq(vault.principal(), next, "the agent blocked the principal's handover to the key it chose");
    }

    /// The same, after the principal closed the agent and turned off its delegation. Fails today: `grant` checks only
    /// that the direct parent is not closed (`CrestVault.sol:116`), and authority above a grant (`_above`) ignores the
    /// state of the grant that gives it, so a closed agent still grants under its open sub-agent.
    function test_attack_closedAgentStillTakesKeySlotsThroughItsSubAgent() public {
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _wide(), 0, "");
        address next = makeAddr("next principal");
        vm.startPrank(principal);
        vault.setCaps(agentGrant, _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, false), "");
        vault.close(agentGrant, "");
        vault.proposePrincipal(next, "");
        vm.stopPrank();

        vm.prank(buyer);
        try vault.grant(subGrant, next, _wide(), 0, "") {} catch {}
        vm.prank(next);
        try vault.acceptPrincipal("") {} catch {}

        assertEq(vault.principal(), next, "a closed agent with delegation off still blocked the handover");
    }

    /// The principal makes itself a child vault under the root and fills it, then hands the vault to a new key (after a
    /// leak, say). The old key still owns that child, whose parent grant is the root, which has no limits and no list,
    /// and it pays a merchant no one listed. Fails at `2b41c01`: `acceptPrincipal` moved the root and not the children made
    /// under it. At `8c81641` a top vault refuses a child under its root (`NoChildFromTheRoot`), so the old key is left
    /// with nothing to pay from, which the test also checks.
    function test_attack_previousPrincipalPaysFromItsRootChildAfterTheHandover_refused() public {
        CrestVault mine;
        vm.prank(principal);
        try vault.createChild(ROOT, bytes32("principal's own"), "") returns (address c) {
            mine = CrestVault(c);
            vm.prank(principal);
            vault.fundChild(address(mine), 2 * HOLD, "");
        } catch {}
        address next = makeAddr("next principal");
        vm.prank(principal);
        vault.proposePrincipal(next, "");
        vm.prank(next);
        vault.acceptPrincipal("");

        assertEq(vault.grantOf(principal), 0, "the old key kept a grant in the vault");
        assertFalse(vault.authorityOver(principal, ROOT), "the old key kept authority in the vault");
        H.Terms memory t = _vterms(address(mine) == address(0) ? address(vault) : address(mine), principal);
        t.sellerPayoutAddress = vm.addr(OTHER_PK);
        bool paid = _tryFundVia(t, PRINCIPAL_PK);
        assertFalse(paid, "the previous principal's key paid from the vault's money after the handover");
    }

    // The factory and IDs

    /// Grant IDs do not name their vault, so a stranger's own vault can mint the agent's grant ID. It still cannot take
    /// the address of the agent's child vault first: the child's address follows from the calling vault.
    function test_attack_anotherVaultTakesTheAgentsChildAddressFirst_refused() public {
        address predicted = factory.childAddressOf(address(vault), buyer, agentGrant, bytes32("c"));
        vm.prank(stranger);
        CrestVault theirs = CrestVault(factory.create(stranger, address(usdc), 0));
        vm.prank(stranger);
        uint256 g = theirs.grant(ROOT, buyer, _wide(), 0, "");
        assertEq(g, agentGrant, "observed: the same grant ID in another vault");
        vm.prank(stranger);
        address squat = theirs.createChild(g, bytes32("c"), "");

        assertTrue(squat != predicted, "a stranger's vault took the agent's child address");
        vm.prank(buyer);
        address real = vault.createChild(agentGrant, bytes32("c"), "");
        assertEq(real, predicted);
        assertEq(CrestVault(real).parent(), address(vault));
    }

    /// Creating the agent's child again, by the agent or by the principal, returns the same child and resets nothing.
    function test_attack_createTheAgentsChildAgain_resetsNothing() public {
        (CrestVault child, uint256 subInChild) = _agentChild(2 * HOLD);
        vm.prank(buyer);
        assertEq(vault.createChild(agentGrant, 0, ""), address(child));
        vm.prank(principal);
        assertEq(vault.createChild(agentGrant, 0, ""), address(child));
        assertEq(child.principal(), buyer);
        assertEq(child.getGrant(subInChild).controller, sub);
        assertEq(usdc.balanceOf(address(child)), 2 * HOLD);
    }

    /// A clone of the vault's code that the factory did not make, initialized with the principal's vault as its parent and
    /// the root as its parent grant. It gets no money and no authority from the principal's vault.
    function test_attack_aVaultTheFactoryDidNotMakeClaimsThePrincipalsRootAsItsParent() public {
        CrestVault rogue = CrestVault(LibClone.clone(factory.IMPLEMENTATION()));
        rogue.initialize(stranger, address(usdc), address(vault), ROOT);
        assertFalse(factory.isVault(address(rogue)));

        vm.startPrank(stranger);
        vm.expectRevert(ICrestVault.UnknownChild.selector);
        vault.fundChild(address(rogue), HOLD, "");
        vm.expectRevert(ICrestVault.UnknownChild.selector);
        vault.takeBackFromChild(address(rogue), HOLD, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setPaused(agentGrant, true, "");
        vm.stopPrank();
        assertFalse(vault.authorityOver(stranger, ROOT));
        assertFalse(vault.authorityOver(address(rogue), ROOT));

        // A clone that names itself as its parent loops until it runs out of gas, and harms only itself.
        CrestVault loop = CrestVault(LibClone.clone(factory.IMPLEMENTATION()));
        address self = address(loop);
        loop.initialize(stranger, address(usdc), self, ROOT);
        try loop.payeeOf{gas: 5_000_000}(address(module)) returns (address p) {
            assertEq(p, address(0), "a looping clone answered with a payee");
        } catch {}
        assertFalse(_tryFundVia(_vterms(address(loop), stranger), OTHER_PK), "a looping clone funded a deal");
        assertEq(usdc.balanceOf(address(vault)), 1_000 * HOLD, "the principal's vault is untouched");
    }

    // Periods

    /// The agent has spent its day (three holds). The principal changes its limit to four holds a week, meaning four in
    /// this week at most. Changing the period moves the window's index, and `_chargeOne` (`CrestVault.sol:347-348`)
    /// then counts the window from zero, so the agent pays four more holds at once: seven in the week the principal capped
    /// at four. Fails today.
    function test_attack_ownerChangesThePeriod_agentGetsAFreshWindowAtOnce_refused() public {
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 100, true, true));
        for (uint256 i; i < 3; i++) {
            _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        }
        ICrestVault.Caps memory weekly = _caps(HOLD, 4 * HOLD, type(uint128).max, 100, true, true);
        weekly.period = 7 days;
        _setAgentCaps(weekly);

        uint256 more;
        for (uint256 i; i < 4; i++) {
            if (_tryFundVia(_vterms(address(vault), buyer), BUYER_PK)) more++;
        }
        assertLe(3 + more, 4, "the agent paid more in the week than the weekly limit the principal set");
    }

    // Commitments and counts

    /// Closing a deal twice, or closing terms the vault never funded once their escrow has expired, frees nothing.
    function test_attack_closeADealTwiceOrOneTheVaultNeverOpened_refused() public {
        H.Terms memory t1 = _vterms(address(vault), buyer);
        bytes32 id1 = _fundVia(t1, BUYER_PK);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        _release(t1, id1);
        module.close(t1);
        vm.expectRevert(ICrestVault.NotOpen.selector);
        module.close(t1);
        assertEq(_grantOf(vault, agentGrant).open, 1, "the second deal still counts");
        assertEq(_grantOf(vault, ROOT).open, 1);

        H.Terms memory never = _vterms(address(vault), buyer);
        vm.warp(uint256(never.timing.fallbackBy) + never.timing.appealDecideSec + rules.EXPIRY_MARGIN());
        vm.expectRevert(ICrestVault.NotOpen.selector);
        module.close(never);
        assertEq(_grantOf(vault, agentGrant).open, 1);
    }

    // Gas

    /// The agent builds a chain of 200 grants inside its child vault and hangs a grandchild at the bottom, so every
    /// authority check on the grandchild walks the chain. The principal's clawback must stay cheaper than the agent's
    /// funding, so whatever the agent could fund within a transaction's gas, the principal can take back; and the principal's
    /// stop at the agent's grant must not grow with depth. Measured warm here (one transaction); rerun with
    /// `forge test --isolate --match-test test_attack_deepGrantChain` for cold storage.
    function test_attack_deepGrantChainUnderAGrandchildOutpricesThePrincipalsClawback() public {
        (CrestVault child,) = _agentChild(3 * HOLD);
        uint256 depth = 200;
        uint256 g = ROOT;
        vm.startPrank(buyer);
        for (uint256 i; i < depth; i++) {
            g = child.grant(g, address(uint160(0xC0DE0000 + i)), _wide(), 0, "");
        }
        CrestVault deep = CrestVault(child.createChild(g, 0, ""));
        uint256 g0 = gasleft();
        child.fundChild(address(deep), HOLD, "");
        uint256 agentGas = g0 - gasleft();
        vm.stopPrank();

        vm.prank(principal);
        g0 = gasleft();
        deep.returnToParent(HOLD, "");
        uint256 ownerGas = g0 - gasleft();

        vm.prank(principal);
        g0 = gasleft();
        vault.setPaused(agentGrant, true, "");
        uint256 stopGas = g0 - gasleft();

        emit log_named_uint("grant chain depth", depth);
        emit log_named_uint("agent's funding of the grandchild, gas", agentGas);
        emit log_named_uint("principal's clawback from the grandchild, gas", ownerGas);
        emit log_named_uint("principal's stop at the agent's grant, gas", stopGas);
        assertLt(ownerGas, agentGas, "the principal's clawback costs more than the agent's funding");
        assertLt(stopGas, 60_000, "the principal's stop grew with the depth of the agent's tree");
        assertEq(usdc.balanceOf(address(child)), 3 * HOLD);
    }

    /// A chain of child vaults: each of the agent's own vaults makes the next under its root, so the agent pushes money
    /// down one hop at a time, cheaply, while every authority check on the deepest vault walks every vault above it.
    /// Measured: the agent's cost to make and fill the chain, against the principal's cost to bring the money back to the
    /// top one hop at a time. Rerun with `--isolate` for cold storage.
    function test_attack_deepVaultChainOutpricesThePrincipalsRecovery() public {
        uint256 depth = 20;
        CrestVault[] memory chain = new CrestVault[](depth + 1);
        (chain[0],) = _agentChild(2 * HOLD);
        uint256 agentGas;
        uint256 g0;
        vm.startPrank(buyer);
        for (uint256 i = 1; i <= depth; i++) {
            g0 = gasleft();
            chain[i] = CrestVault(chain[i - 1].createChild(ROOT, 0, ""));
            chain[i - 1].fundChild(address(chain[i]), 2 * HOLD, "");
            agentGas += g0 - gasleft();
        }
        vm.stopPrank();

        uint256 ownerGas;
        uint256 deepestHop;
        for (uint256 i = depth; i >= 1; i--) {
            vm.prank(principal);
            g0 = gasleft();
            chain[i].returnToParent(2 * HOLD, "");
            uint256 hop = g0 - gasleft();
            ownerGas += hop;
            if (i == depth) deepestHop = hop;
        }
        vm.prank(principal);
        vault.takeBackFromChild(address(chain[0]), 2 * HOLD, "");

        emit log_named_uint("vault chain depth", depth);
        emit log_named_uint("agent's cost to make and fill the chain, gas", agentGas);
        emit log_named_uint("principal's cost to bring the money back to the top, gas", ownerGas);
        emit log_named_uint("principal's single deepest hop, gas", deepestHop);
        assertEq(usdc.balanceOf(address(vault)), 1_000 * HOLD, "every unit came back");
        assertLt(ownerGas, agentGas, "the principal's recovery costs more than the agent's chain");
    }
}
