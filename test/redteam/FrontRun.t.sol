// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {RedTeamBase} from "./RedTeamBase.sol";

/// Red team: an agent front-runs its principal's stop.
///
/// The principal stops an agent with a transaction: a pause, a close, a narrowing, a withdrawal, an unlisted merchant
/// or a disabled module. The agent sees it waiting to be included and lands everything it can first, at any gas price.
/// Each test lands the agent's transactions first and the principal's second, then shows three things:
/// - the stop still lands: nothing the agent does makes it revert;
/// - nothing the agent landed can pay or delegate after it;
/// - what left the vault is bounded by the agent's limits, and sits either in holds for a merchant on the agent's list,
///   which settle by their terms, or in a child vault the principal takes back.
///
/// The agent's grant in `CrestBase`: one hold per deal, three holds a period, two open at once, one listed merchant.
/// Every `test_attack_*` passes when the defence holds and fails when the attack works.
contract RedTeamFrontRunTest is RedTeamBase {
    bytes32 internal constant CAPS_TYPEHASH = keccak256(
        "Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    bytes32 internal constant SIGNED_GRANT_TYPEHASH = keccak256(
        "SignedGrant(uint256 parent,address controller,Caps caps,bytes32 salt,uint40 deadline,bytes note)Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );

    enum Stop {
        PauseAgent,
        CloseAgent,
        PauseRoot
    }

    // 1. The stop always lands

    /// The agent grants a key, creates and fills a child vault, then pauses and closes its own grant, all ahead of the
    /// principal. The principal's pause, close, root pause and narrowing of that grant all still land.
    function test_attack_nothingTheAgentLandsFirstMakesTheStopRevert() public {
        vm.startPrank(buyer);
        vault.grant(agentGrant, sub, _wide(), 0, "");
        address child = vault.createChild(agentGrant, 0, "");
        vault.fundChild(child, HOLD, "");
        vault.setPaused(agentGrant, true, "");
        vault.close(agentGrant, "");
        vm.stopPrank();

        vm.startPrank(principal);
        vault.setPaused(agentGrant, true, "stop");
        vault.close(agentGrant, "stop");
        vault.setPaused(ROOT, true, "stop everything");
        vault.setCaps(agentGrant, _caps(0, 0, 0, 0, true, false), "narrow");
        vault.takeBackFromChild(child, HOLD, "back");
        vm.stopPrank();
        assertTrue(_grantOf(vault, agentGrant).closed);
        assertTrue(_grantOf(vault, ROOT).paused);
    }

    // 2. Keys the agent grants first cannot pay after the stop

    function test_attack_keysGrantedAheadOfAPause_cannotPayOrDelegate() public {
        _keysAheadOf(Stop.PauseAgent);
    }

    function test_attack_keysGrantedAheadOfAClose_cannotPayOrDelegate() public {
        _keysAheadOf(Stop.CloseAgent);
    }

    function test_attack_keysGrantedAheadOfARootPause_cannotPayOrDelegate() public {
        _keysAheadOf(Stop.PauseRoot);
    }

    /// The agent grants its own second key by transaction, and has anyone land a slip it signed for a third. After the
    /// stop, neither key pays or delegates, the agent's slip for a fourth key no longer lands, and the agent itself pays
    /// nothing. No money moved.
    function _keysAheadOf(Stop stop) internal {
        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _wide(), 0, "");
        ICrestVault.SignedGrant memory first = _slip(agentGrant, sub2, "first");
        vm.prank(stranger);
        vault.grantBySig(first, _signedBy(BUYER_PK, first));
        ICrestVault.SignedGrant memory late = _slip(agentGrant, makeAddr("fourth key"), "late");
        bytes memory lateSig = _signedBy(BUYER_PK, late);

        _stop(stop);

        bytes memory err = _errFor(stop);
        _expectRefused(_vterms(address(vault), sub), SUB_PK, err);
        _expectRefused(_vterms(address(vault), sub2), SUB2_PK, err);
        vm.prank(sub);
        vm.expectRevert(err);
        vault.grant(subGrant, makeAddr("grandchild"), _wide(), 0, "");
        vm.expectRevert(err);
        vault.grantBySig(late, lateSig);
        _expectRefused(
            _vterms(address(vault), buyer),
            BUYER_PK,
            stop == Stop.CloseAgent ? abi.encodeWithSelector(ICrestVault.NoGrant.selector) : err
        );
        assertEq(usdc.balanceOf(address(vault)), before, "no money moved");
    }

    // 3. Money the agent moves into a child vault first

    /// The agent creates a child vault and fills it with all its period allows, ahead of a close. One unit more is
    /// refused, so the move is bounded by the agent's own limits. After the close, a key the agent grants in the child
    /// cannot pay, the agent cannot withdraw from the child or fill it again, and the principal takes it all back.
    function test_attack_moneyMovedIntoAChildVaultAheadOfAClose_isBoundedAndComesBack() public {
        uint256 before = usdc.balanceOf(address(vault));
        uint256 agentBefore = usdc.balanceOf(buyer);
        vm.startPrank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vault.fundChild(address(child), 3 * HOLD, "");
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentGrant));
        vault.fundChild(address(child), 1, "");
        child.grant(ROOT, sub, _wide(), 0, "");
        vm.stopPrank();
        assertEq(before - usdc.balanceOf(address(vault)), 3 * HOLD, "bounded by the agent's period limit");

        vm.prank(principal);
        vault.close(agentGrant, "stop");

        bytes memory closed = abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant);
        _expectRefused(_vterms(address(child), sub), SUB_PK, closed);
        vm.startPrank(buyer);
        vm.expectRevert(ICrestVault.NotTopVault.selector);
        child.withdraw(buyer, 1, "");
        vm.expectRevert(closed);
        vault.fundChild(address(child), 1, "");
        vm.stopPrank();

        vm.prank(principal);
        vault.takeBackFromChild(address(child), 3 * HOLD, "back");
        assertEq(usdc.balanceOf(address(vault)), before, "the principal took it all back");
        assertEq(usdc.balanceOf(buyer), agentBefore, "the agent's key gained nothing");
    }

    // 4. Holds the agent funds first

    /// The agent funds every hold it can ahead of the principal's stop: two (its open limit), each within its
    /// per-payment limit, both for its one listed merchant; a third and an unlisted payout address are refused. The
    /// principal then pauses the root, closes the agent, unlists the merchant and disables the module. The vault is out
    /// two holds, the worst case these limits allow. Neither needs the principal's key to come back: the merchant
    /// lets one lapse undelivered and anyone reclaims it at its delivery deadline, and the merchant and the agent's
    /// key settle the other as a full refund. The agent's key never receives anything.
    function test_attack_holdsFundedAheadOfAStop_stayWithinTheLimitsAndTheList_andCanComeBack() public {
        uint256 before = usdc.balanceOf(address(vault));
        uint256 agentBefore = usdc.balanceOf(buyer);
        H.Terms memory t1 = _vterms(address(vault), buyer);
        bytes32 id1 = _fundVia(t1, BUYER_PK);
        H.Terms memory t2 = _vterms(address(vault), buyer);
        bytes32 id2 = _fundVia(t2, BUYER_PK);
        _expectRefused(
            _vterms(address(vault), buyer),
            BUYER_PK,
            abi.encodeWithSelector(ICrestVault.TooManyOpen.selector, agentGrant)
        );
        H.Terms memory elsewhere = _vterms(address(vault), buyer);
        elsewhere.sellerPayoutAddress = vm.addr(OTHER_PK);
        _expectRefused(
            elsewhere, BUYER_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant)
        );

        vm.startPrank(principal);
        vault.setPaused(ROOT, true, "stop everything");
        vault.close(agentGrant, "stop");
        allowList.set(vault, agentGrant, _merchant(), false, "");
        vault.setModule(address(module), address(0), "");
        vm.stopPrank();
        assertEq(
            before - usdc.balanceOf(address(vault)),
            2 * HOLD,
            "the worst case: the open limit times the per-payment limit"
        );

        H.Payout[] memory refund = new H.Payout[](1);
        refund[0] = H.Payout(address(vault), PRICE);
        H.Mutual memory m = _mutualAsAgent(t2, id2, refund);
        H.KeyProof memory none;
        rules.mutualSettle(t2, m, _noDelivery(), none);
        assertEq(uint8(_stage(id2)), uint8(IHoldbackRules.Stage.Settled));

        vm.warp(t1.timing.deliverBy);
        vm.prank(stranger);
        rules.reclaim(t1);
        assertEq(uint8(_stage(id1)), uint8(IHoldbackRules.Stage.Refunded));

        assertEq(usdc.balanceOf(address(vault)), before, "both holds came back to the vault");
        assertEq(usdc.balanceOf(buyer), agentBefore, "the agent's key received nothing");
        module.close(t1);
        module.close(t2);
        assertEq(_grantOf(vault, agentGrant).open, 0);
    }

    // 5. Spending ahead of a narrowing

    /// The agent grants a key with no limits of its own and both fund a hold ahead of a narrowing to two holds a
    /// period. What left is within the old limits; after the narrowing, neither the agent nor its key pays again: the
    /// narrowing binds every grant below it at payment time.
    function test_attack_spendingAheadOfANarrowing_isBoundedByTheOldLimits_andStopsAtTheNew() public {
        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(buyer);
        vault.grant(agentGrant, sub, _wide(), 0, "");
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        _fundVia(_vterms(address(vault), sub), SUB_PK);

        _setAgentCaps(_caps(HOLD, 2 * HOLD, type(uint128).max, 10, true, true));

        bytes memory over = abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentGrant);
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, over);
        _expectRefused(_vterms(address(vault), sub), SUB_PK, over);
        assertEq(before - usdc.balanceOf(address(vault)), 2 * HOLD, "within the old limit of three holds a period");
    }

    // 6. A withdrawal of everything

    /// The principal reads the balance and sends a withdrawal of all of it; the agent funds a hold first. The stale
    /// withdrawal reverts and moves nothing. Paused first, the agent cannot spend, so a withdrawal of the balance read
    /// after the pause lands, and the vault is empty except for what the agent had already committed.
    function test_attack_aStaleWithdrawalOfEverythingReverts_andPausingFirstMakesItLand() public {
        uint256 read = usdc.balanceOf(address(vault));
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);

        vm.prank(principal);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        vault.withdraw(principal, read, "everything");
        assertEq(usdc.balanceOf(address(vault)), read - HOLD, "the stale withdrawal moved nothing");

        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop");
        _expectRefused(
            _vterms(address(vault), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant)
        );
        uint256 rest = usdc.balanceOf(address(vault));
        vm.prank(principal);
        vault.withdraw(principal, rest, "everything");
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(principal), rest);
    }

    // 7. A signed grant the principal sends

    /// The principal signs a slip for a new key and sends it. The agent sees it and gives that key a grant of its own
    /// first, so the slip no longer lands (`KeyNotFresh`). This only delays: the principal grants the key by
    /// transaction, which closes the agent's grant to it.
    function test_attack_theAgentBlocksAPrincipalSlipByGrantingTheKeyFirst_theTransactionGrantStillLands() public {
        address key = makeAddr("new agent");
        ICrestVault.SignedGrant memory s = _slip(ROOT, key, "new agent");
        bytes memory sig = _signedBy(PRINCIPAL_PK, s);
        vm.prank(buyer);
        uint256 agents = vault.grant(agentGrant, key, _wide(), 0, "");

        vm.expectRevert(ICrestVault.KeyNotFresh.selector);
        vault.grantBySig(s, sig);

        vm.prank(principal);
        uint256 id = vault.grant(ROOT, key, s.caps, s.salt, "by transaction");
        assertEq(vault.grantOf(key), id);
        assertTrue(_grantOf(vault, agents).closed, "the agent's grant to the key closed");
    }

    // Helpers

    function _stop(Stop stop) internal {
        vm.prank(principal);
        if (stop == Stop.PauseAgent) vault.setPaused(agentGrant, true, "stop");
        else if (stop == Stop.CloseAgent) vault.close(agentGrant, "stop");
        else vault.setPaused(ROOT, true, "stop everything");
    }

    function _errFor(Stop stop) internal view returns (bytes memory) {
        if (stop == Stop.PauseAgent) return abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant);
        if (stop == Stop.CloseAgent) return abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant);
        return abi.encodeWithSelector(ICrestVault.Paused.selector, ROOT);
    }

    /// One hold at a time, two a period, no right to delegate, no list of its own.
    function _slip(uint256 parentId, address controller, bytes32 salt)
        internal
        view
        returns (ICrestVault.SignedGrant memory)
    {
        return ICrestVault.SignedGrant({
            parent: parentId,
            controller: controller,
            caps: _caps(HOLD, 2 * HOLD, type(uint128).max, 1, false, false),
            salt: salt,
            deadline: uint40(vm.getBlockTimestamp() + 1 hours),
            note: ""
        });
    }

    function _signedBy(uint256 pk, ICrestVault.SignedGrant memory s) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Crest"),
                keccak256("1"),
                block.chainid,
                address(vault)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNED_GRANT_TYPEHASH,
                s.parent,
                s.controller,
                keccak256(abi.encode(CAPS_TYPEHASH, s.caps)),
                s.salt,
                s.deadline,
                keccak256(s.note)
            )
        );
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, ss, v);
    }
}
