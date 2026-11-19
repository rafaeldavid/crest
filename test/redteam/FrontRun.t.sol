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
/// The principal stops an agent with a transaction: a pause, a close, a narrowing, an unlisted merchant, a disabled
/// module, a withdrawal, a take-back from a child vault, or a cancel of a slip. The agent sees it waiting to be
/// included and lands everything it can first, at any gas price. Each test lands the agent's transactions first and the
/// principal's second, then shows:
/// - a pause, a close, a narrowing, an unlisting or a module switch-off still lands, whatever the agent did;
/// - a stop that names an amount or an ID (a withdrawal, a take-back, a cancel) can go stale and revert, moving nothing;
/// - after a pause or a close, nothing the agent landed can pay or delegate;
/// - what left the vault is bounded by the agent's period and lifetime limits, and sits either in holds for a merchant
///   on the agent's list, which settle by their terms, or in a child vault the principal takes back.
///
/// One thing the agent's key keeps after every stop while it is the deal's buyer: it can accept early a hold whose
/// merchant has signed a delivery (`test_observe_*` below; ADR-0041 section 4). The vault as the buyer closes it.
///
/// The agent's grant in `CrestBase`: one hold per deal, three holds a period, two open at once, one listed merchant.
/// Every `test_attack_*` passes when the defence holds and fails when the attack works. A `test_observe_*` records a
/// behaviour as it is.
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

    // 1. A pause, a close, a narrowing, an unlisting and a module switch-off always land

    /// The agent grants a key, creates and fills a child vault and funds a hold, keeping its own grant open. The
    /// principal's narrowing, unlisting, module switch-off, pause, close and root pause all land, and so does its
    /// take-back of the child's balance, which the agent did not spend.
    function test_attack_nothingTheAgentLandsFirstMakesAPauseOrACloseRevert() public {
        vm.startPrank(buyer);
        vault.grant(agentGrant, sub, _wide(), 0, "");
        address child = vault.createChild(agentGrant, 0, "");
        vault.fundChild(child, HOLD, "");
        vm.stopPrank();
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        assertFalse(_grantOf(vault, agentGrant).paused);
        assertFalse(_grantOf(vault, agentGrant).closed);

        vm.startPrank(principal);
        vault.setCaps(agentGrant, _caps(0, 0, 0, 0, true, false), "narrow");
        allowList.set(vault, agentGrant, _merchant(), false, "unlist");
        vault.setModule(address(module), address(0), "module off");
        vault.setPaused(agentGrant, true, "stop");
        vault.close(agentGrant, "stop");
        vault.setPaused(ROOT, true, "stop everything");
        vault.takeBackFromChild(child, HOLD, "back");
        vm.stopPrank();
        assertTrue(_grantOf(vault, agentGrant).closed);
        assertTrue(_grantOf(vault, ROOT).paused);
    }

    /// The agent pauses and closes its own grant first. The principal's pause, close, root pause and narrowing of that
    /// grant still land.
    function test_attack_theAgentStoppingItselfFirst_doesNotMakeThePrincipalsStopsRevert() public {
        vm.startPrank(buyer);
        vault.setPaused(agentGrant, true, "");
        vault.close(agentGrant, "");
        vm.stopPrank();

        vm.startPrank(principal);
        vault.setPaused(agentGrant, true, "stop");
        vault.close(agentGrant, "stop");
        vault.setPaused(ROOT, true, "stop everything");
        vault.setCaps(agentGrant, _caps(0, 0, 0, 0, true, false), "narrow");
        vm.stopPrank();
        assertTrue(_grantOf(vault, agentGrant).closed);
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
    /// stop, neither key pays or delegates, the agent's slip for a fourth key does not land, and the agent itself pays
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

    /// A pause holds a slip back only while it stands: once the principal resumes the grant, a slip the agent signed
    /// earlier lands again until its deadline. After a close it never lands (the close variant above).
    function test_observe_aSlipHeldThroughAPause_landsOnceThePrincipalResumes() public {
        ICrestVault.SignedGrant memory s = _slip(agentGrant, sub, "held");
        bytes memory sig = _signedBy(BUYER_PK, s);
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop");
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant));
        vault.grantBySig(s, sig);

        vm.prank(principal);
        vault.setPaused(agentGrant, false, "resume");
        uint256 id = vault.grantBySig(s, sig);
        assertEq(vault.grantOf(sub), id);
    }

    // 3. Money the agent moves into a child vault first

    /// The agent creates a child vault and fills it with all its period allows, ahead of a close. One unit more is
    /// refused, so the move is bounded by the agent's own limits. After the close, neither the agent nor a key it grants
    /// in the child can pay from it, the agent cannot fill it again, and the principal takes it all back.
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
        _expectRefused(_vterms(address(child), buyer), BUYER_PK, closed);
        _expectRefused(_vterms(address(child), sub), SUB_PK, closed);
        vm.prank(buyer);
        vm.expectRevert(closed);
        vault.fundChild(address(child), 1, "");

        vm.prank(principal);
        vault.takeBackFromChild(address(child), 3 * HOLD, "back");
        assertEq(usdc.balanceOf(address(vault)), before, "the principal took it all back");
        assertEq(usdc.balanceOf(buyer), agentBefore, "the agent's key gained nothing");
    }

    /// From review test A. A child vault's payments check the parent grant's state, per-payment limit and list, not its
    /// open count, so through a child the agent opens three holds against an open limit of two: its whole period limit,
    /// all for the listed merchant. The principal's take-back of the child balance it read goes stale and reverts.
    function test_attack_holdsPaidFromAChild_passTheOpenLimit_butStayWithinThePeriodLimit() public {
        uint256 before = usdc.balanceOf(address(vault));
        vm.startPrank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vault.fundChild(address(child), 3 * HOLD, "");
        vm.stopPrank();
        uint256 read = usdc.balanceOf(address(child));

        _fundVia(_vterms(address(child), buyer), BUYER_PK);
        _fundVia(_vterms(address(child), buyer), BUYER_PK);
        _fundVia(_vterms(address(child), buyer), BUYER_PK);
        assertEq(_grantOf(vault, agentGrant).caps.maxOpen, 2);
        assertEq(_grantOf(child, ROOT).open, 3, "three holds open at once from the child");
        H.Terms memory elsewhere = _vterms(address(child), buyer);
        elsewhere.sellerPayoutAddress = vm.addr(OTHER_PK);
        _expectRefused(
            elsewhere, BUYER_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant)
        );

        vm.startPrank(principal);
        vault.close(agentGrant, "stop");
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        vault.takeBackFromChild(address(child), read, "back");
        vm.stopPrank();

        assertEq(before - usdc.balanceOf(address(vault)), 3 * HOLD, "the period limit is the bound");
        _expectRefused(
            _vterms(address(child), buyer),
            BUYER_PK,
            abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant)
        );
    }

    // 4. Holds the agent funds first

    /// The agent funds two holds ahead of the principal's stop, as many as its open limit allows at once; a third and an
    /// unlisted payout address are refused. The principal then pauses the root, closes the agent, unlists the merchant
    /// and disables the module. Neither hold needs the principal's key to come back: the merchant lets one lapse
    /// undelivered and anyone reclaims it at its delivery deadline, and the merchant and the agent's key settle the
    /// other as a full refund. The agent's key never receives anything.
    function test_attack_holdsFundedAheadOfAStop_stayOnTheList_andUndeliveredOnesCanComeBack() public {
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
        assertEq(before - usdc.balanceOf(address(vault)), 2 * HOLD, "two holds while both stay open");

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

    /// From review test B. With a merchant that delivers at once, the agent accepts one hold early, ends it with the
    /// module's `close` (anyone may call it), and funds a third, all ahead of a pause. The open limit caps holds open at
    /// once, not holds funded: more than two holds' worth leaves, and the period limit stops the next one.
    function test_attack_reusingSlotsByAcceptingEarly_stopsAtThePeriodLimit() public {
        uint256 before = usdc.balanceOf(address(vault));
        H.Terms memory t1 = _vterms(address(vault), buyer);
        bytes32 id1 = _fundVia(t1, BUYER_PK);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        _earlyAcceptAsAgent(t1, id1);
        module.close(t1);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        H.Terms memory t4 = _vterms(address(vault), buyer);
        _expectRefused(t4, BUYER_PK, abi.encodeWithSelector(ICrestVault.TooManyOpen.selector, agentGrant));
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, true));
        _expectRefused(
            _vterms(address(vault), buyer),
            BUYER_PK,
            abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentGrant)
        );

        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop");
        assertEq(before - usdc.balanceOf(address(vault)), 2 * HOLD + PRICE, "two holds held and one price paid out");
        assertEq(_grantOf(vault, agentGrant).inPeriod, 3 * HOLD, "the period limit was the bound");
    }

    /// From review test C. While the agent's key is the deal's buyer, it keeps one act after every stop the principal
    /// has: it accepts early a hold whose merchant has signed a delivery, and the price goes to that merchant with no
    /// judgment. The deal can then no longer lapse. ADR-0041 section 4 records it; `Neutrality.t.sol` measures it too.
    /// The vault as the buyer closes it: the vault then refuses a stopped agent's signature.
    function test_observe_afterEveryStop_theAgentsKeyStillAcceptsADeliveredHoldEarly() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.startPrank(principal);
        vault.setPaused(ROOT, true, "stop everything");
        vault.close(agentGrant, "stop");
        allowList.set(vault, agentGrant, _merchant(), false, "");
        vault.setModule(address(module), address(0), "");
        vm.stopPrank();

        _earlyAcceptAsAgent(t, id);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Released));
        assertEq(usdc.balanceOf(seller) - sellerBefore, PRICE, "the listed merchant was paid after the stop");
        vm.warp(t.timing.deliverBy);
        vm.expectRevert(abi.encodeWithSelector(IHoldbackRules.WrongStage.selector, IHoldbackRules.Stage.Released));
        rules.reclaim(t);
    }

    // 5. Spending ahead of a narrowing

    /// The open limit is raised to ten first, so the period limit is what binds. The agent and a key it granted spend
    /// the whole old period limit of three holds ahead of a narrowing to two, and a fourth is refused by the old limit.
    /// In the next period the narrowing binds both: two holds, and the third is refused where the old limit allowed it.
    function test_attack_spendingAheadOfANarrowing_isBoundedByTheOldLimits_andStopsAtTheNew() public {
        uint256 before = usdc.balanceOf(address(vault));
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, true));
        vm.prank(buyer);
        vault.grant(agentGrant, sub, _wide(), 0, "");
        bytes memory over = abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentGrant);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        _expectRefused(_vterms(address(vault), sub), SUB_PK, over);
        assertEq(before - usdc.balanceOf(address(vault)), 3 * HOLD, "the old limit of three holds a period");

        _setAgentCaps(_caps(HOLD, 2 * HOLD, type(uint128).max, 10, true, true));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, over);
        _expectRefused(_vterms(address(vault), sub), SUB_PK, over);
        assertEq(before - usdc.balanceOf(address(vault)), 5 * HOLD, "two holds in the period after the narrowing");
    }

    // 6. Stops that name an amount or an ID

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

    /// From review test D. The principal sends a cancel to void a slip the agent signed; the slip's holder lands it
    /// first, and the cancel reverts `GrantExists`. A close of the landed grant, sent next, lands.
    function test_attack_aSlipLandedAheadOfItsCancel_makesTheCancelRevert_andACloseStillLands() public {
        address key = makeAddr("slip key");
        ICrestVault.SignedGrant memory s = _slip(agentGrant, key, "slip");
        bytes memory sig = _signedBy(BUYER_PK, s);
        vm.prank(stranger);
        uint256 landed = vault.grantBySig(s, sig);

        vm.prank(principal);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.cancelSignedGrant(agentGrant, key, "slip", "void the agent's slip");

        vm.prank(principal);
        vault.close(landed, "close it instead");
        assertTrue(_grantOf(vault, landed).closed);
    }

    // 7. Stops narrower than a pause

    /// An unlisting alone stops payments to that merchant, from the vault and from a child vault the agent filled, but
    /// not the agent's other acts: it still fills the child. A pause stops both.
    function test_attack_anUnlistingAlone_stopsPaymentsToThatMerchant_butNotFillingAChild() public {
        vm.startPrank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vault.fundChild(address(child), HOLD, "");
        vm.stopPrank();

        bytes32 merchant = _merchant();
        vm.prank(principal);
        allowList.set(vault, agentGrant, merchant, false, "unlist");

        bytes memory unlisted = abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant);
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, unlisted);
        _expectRefused(_vterms(address(child), buyer), BUYER_PK, unlisted);
        vm.prank(buyer);
        vault.fundChild(address(child), HOLD, "");

        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant));
        vault.fundChild(address(child), HOLD, "");
    }

    /// A module switch-off alone stops every payment through that module, from the vault and from its child vaults,
    /// which inherit the top vault's modules. It does not stop the agent filling a child; a pause does.
    function test_attack_aModuleSwitchOffAlone_stopsPaymentsFromTheVaultAndItsChildren() public {
        vm.startPrank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vault.fundChild(address(child), HOLD, "");
        vm.stopPrank();

        vm.prank(principal);
        vault.setModule(address(module), address(0), "module off");

        bytes memory off = abi.encodeWithSelector(ICrestVault.ModuleNotEnabled.selector);
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, off);
        _expectRefused(_vterms(address(child), buyer), BUYER_PK, off);
        vm.prank(buyer);
        vault.fundChild(address(child), HOLD, "");
    }

    // 8. A signed grant the principal sends

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
