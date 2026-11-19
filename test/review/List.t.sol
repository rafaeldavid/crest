// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestAllowList} from "../../src/CrestAllowList.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestAllowList} from "../../src/ICrestAllowList.sol";
import {ICrestList, ICrestVault} from "../../src/ICrestVault.sol";
import {CrestBase} from "../CrestBase.sol";
import {ScriptedList} from "../List.t.sol";

/// Asks a list exactly as `CrestVault._listAllows` does, with a gas cap the caller picks.
contract ReviewProbe {
    function ask(address list, uint256 cap, address v, uint256 g, bytes32 cp)
        external
        view
        returns (bool yes, uint256 length)
    {
        (bool ok, bytes memory answer) = list.staticcall{gas: cap}(abi.encodeCall(ICrestList.allows, (v, g, cp)));
        return (ok && answer.length == 32 && bytes32(answer) == bytes32(ICrestList.allows.selector), answer.length);
    }
}

/// Says yes after `rounds` loop rounds. No storage, so its cost is the same cold or warm.
contract RoundsList {
    uint256 internal immutable ROUNDS;

    constructor(uint256 rounds) {
        ROUNDS = rounds;
    }

    function allows(address, uint256, bytes32) external view returns (bytes4) {
        uint256 n = ROUNDS;
        assembly {
            for {} n {} { n := sub(n, 1) }
        }
        return ICrestList.allows.selector;
    }
}

/// Says yes only when it gets less gas than the vault's cap; on that branch it reads one slot, which `vm.accesses`
/// sees, so a scan can show it reached the branch.
contract StarvedList {
    uint256 public marker;

    function allows(address, uint256, bytes32) external view returns (bytes4) {
        if (gasleft() < 29_000) return marker == 7 ? bytes4(0) : ICrestList.allows.selector;
        return bytes4(0);
    }
}

/// Raw answers: 0 reverts with the magic word, 1 returns 4 bytes of magic, 2 returns 64 bytes that start with the
/// magic word, 3 returns the magic with one dirty low byte, 5 returns 32 zero bytes, anything else returns `size` bytes.
contract RawList {
    uint256 internal immutable MODE;
    uint256 internal immutable SIZE;

    constructor(uint256 mode, uint256 size) {
        (MODE, SIZE) = (mode, size);
    }

    function allows(address, uint256, bytes32) external view returns (bytes4) {
        (uint256 mode, uint256 size) = (MODE, SIZE);
        bytes4 yes = ICrestList.allows.selector;
        assembly {
            mstore(0, yes)
            mstore(32, 0)
            switch mode
            case 0 { revert(0, 32) }
            case 1 { return(0, 4) }
            case 2 { return(0, 64) }
            case 3 {
                mstore8(31, 1)
                return(0, 32)
            }
            case 5 {
                mstore(0, 0)
                return(0, 32)
            }
            default { return(0, size) }
        }
        return yes;
    }
}

/// A list whose `allows` is not view: it writes, then says yes.
contract WritingList {
    uint256 public writes;

    function allows(address, uint256, bytes32) external returns (bytes4) {
        writes++;
        return ICrestList.allows.selector;
    }
}

/// A list that controls a grant above the one it is asked about and, when asked, tries to point that grant at no
/// list. It says yes whatever happens, so the payment goes on and the test can read the grant afterwards.
contract ReenteringList {
    function allows(address v, uint256 g, bytes32) external returns (bytes4) {
        try this.widen{gas: 25_000}(v, g) {} catch {}
        return ICrestList.allows.selector;
    }

    function widen(address v, uint256 g) public {
        ICrestVault.Caps memory c = ICrestVault(v).getGrant(g).caps;
        c.list = address(0);
        ICrestVault(v).setCaps(g, c, "");
    }
}

/// A third party's list: its owner decides whom it allows.
contract OwnedList {
    address internal immutable OWNER;
    bool public yesToAll;

    constructor(address owner) {
        OWNER = owner;
    }

    function setYesToAll(bool y) external {
        require(msg.sender == OWNER);
        yesToAll = y;
    }

    function allows(address, uint256, bytes32) external view returns (bytes4) {
        return yesToAll ? ICrestList.allows.selector : bytes4(0);
    }
}

contract YesImpl {
    function allows(address, uint256, bytes32) external pure returns (bytes4) {
        return ICrestList.allows.selector;
    }
}

contract NoImpl {
    function allows(address, uint256, bytes32) external pure returns (bytes4) {
        return bytes4(0);
    }
}

/// A list behind a proxy whose admin swaps the code it runs.
contract SwapProxyList {
    address public impl;
    address internal immutable ADMIN;

    constructor(address i) {
        (impl, ADMIN) = (i, msg.sender);
    }

    function swap(address i) external {
        require(msg.sender == ADMIN);
        impl = i;
    }

    fallback() external {
        address i = impl;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), i, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

contract SelfDestructingList {
    function allows(address, uint256, bytes32) external pure returns (bytes4) {
        return ICrestList.allows.selector;
    }

    function destroy() external {
        selfdestruct(payable(msg.sender));
    }
}

contract ReviewRegistry {
    mapping(bytes32 => address) public ownerOf;
    mapping(address => bool) public inGoodStanding;

    function register(bytes32 who, address owner) external {
        (ownerOf[who], inGoodStanding[owner]) = (owner, true);
    }
}

/// One cold call to a registry and two cold reads there, as the PR's registry-reading list.
contract ReviewRegistryList {
    ReviewRegistry internal immutable REGISTRY;

    constructor(ReviewRegistry r) {
        REGISTRY = r;
    }

    function allows(address, uint256, bytes32 cp) external view returns (bytes4) {
        address owner = REGISTRY.ownerOf(cp);
        return owner != address(0) && REGISTRY.inGoodStanding(owner) ? ICrestList.allows.selector : bytes4(0);
    }
}

/// Review tests for PR 9. Each `test_review_*` passes when the property it names holds.
contract ListReviewTest is CrestBase {
    bytes32 internal constant CAPS_TYPEHASH = keccak256(
        "Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    bytes32 internal constant SIGNED_GRANT_TYPEHASH = keccak256(
        "SignedGrant(uint256 parent,address controller,Caps caps,bytes32 salt,uint40 deadline,bytes note)Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    uint256 internal constant LIST_GAS = 30_000;

    ReviewProbe internal probe;
    SelfDestructingList internal doomed;

    function setUp() public override {
        super.setUp();
        probe = new ReviewProbe();
        doomed = new SelfDestructingList();
    }

    // Helpers

    function _point(uint256 id, address list) internal {
        ICrestVault.Caps memory c = _grantOf(vault, id).caps;
        c.list = list;
        vm.prank(principal);
        vault.setCaps(id, c, "");
    }

    function _unlisted() internal returns (H.Terms memory t) {
        t = _vterms(address(vault), buyer);
        t.sellerPayoutAddress = makeAddr("unlisted payout");
    }

    function _notAllowed(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, id);
    }

    function _slipSig(uint256 pk, CrestVault v, ICrestVault.SignedGrant memory s)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Crest"),
                keccak256("1"),
                block.chainid,
                address(v)
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
        (uint8 sv, bytes32 r, bytes32 ss) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, ss, sv);
    }

    function _slip(address list) internal view returns (ICrestVault.SignedGrant memory s) {
        s = ICrestVault.SignedGrant({
            parent: agentGrant,
            controller: sub,
            caps: _caps(HOLD, 3 * HOLD, type(uint128).max, 2, false, false),
            salt: bytes32("review"),
            deadline: uint40(vm.getBlockTimestamp() + 1 hours),
            note: ""
        });
        s.caps.list = list;
    }

    /// The least gas a list with no storage needs to say yes.
    function _leastGasForYes(address list, address) internal view returns (uint256 lo) {
        uint256 hi = 200_000;
        lo = 0;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            (bool yes,) = probe.ask(list, mid, address(vault), agentGrant, 0);
            if (yes) hi = mid;
            else lo = mid;
        }
        lo = hi;
    }

    // Q1 and Q2: who may write the default list

    /// For every existing grant and every actor, `CrestAllowList.set` passes exactly when `setCaps` passes, in the
    /// vault and in a child vault. So no one can widen a grant's entries who could not point the grant at no list.
    function test_review_whoMayWriteTheDefaultList_isWhoMaySetTheGrantsCaps() public {
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _wide(), 0, "");
        vm.prank(sub);
        uint256 subSub = vault.grant(subGrant, sub2, _wide(), 0, "");
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vm.prank(buyer);
        uint256 inChild = child.grant(ROOT, sub, _wide(), 0, "");

        address[5] memory who = [principal, buyer, sub, sub2, stranger];
        CrestVault[6] memory vs = [vault, vault, vault, vault, child, child];
        uint256[6] memory ids = [ROOT, agentGrant, subGrant, subSub, ROOT, inChild];
        uint256 checked;
        for (uint256 round; round < 2; ++round) {
            if (round == 1) {
                vm.prank(principal);
                vault.close(agentGrant, "the agent loses its authority");
            }
            for (uint256 i; i < who.length; ++i) {
                for (uint256 j; j < ids.length; ++j) {
                    ICrestVault.Caps memory c = vs[j].getGrant(ids[j]).caps;
                    uint256 snap = vm.snapshotState();
                    vm.prank(who[i]);
                    (bool okSet,) = address(allowList).call(
                        abi.encodeCall(allowList.set, (vs[j], ids[j], keccak256("anyone"), true, ""))
                    );
                    vm.revertToState(snap);
                    vm.prank(who[i]);
                    (bool okCaps,) = address(vs[j]).call(abi.encodeCall(vault.setCaps, (ids[j], c, "")));
                    vm.revertToState(snap);
                    assertEq(okSet, okCaps, "a writer of the list is not a setter of the caps, or the reverse");
                    if (who[i] == buyer && (ids[j] == agentGrant || ids[j] == ROOT)) {
                        assertFalse(okSet, "the agent wrote its own grant's or its child root's entries");
                    }
                    if (who[i] == sub && address(vs[j]) == address(vault) && ids[j] != subSub) {
                        assertFalse(okSet, "the sub-agent wrote an entry at or above its own grant");
                    }
                    ++checked;
                }
            }
        }
        assertEq(checked, 60);
    }

    /// A merchant the principal takes off the default list is refused at the agent's next payment.
    function test_review_aMerchantTakenOffTheList_isRefusedAtTheNextPayment() public {
        bytes32 m = _merchant();
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        vm.prank(principal);
        allowList.set(vault, agentGrant, m, false, "no longer approved");
        assertFalse(allowList.allowed(address(vault), agentGrant, m));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _notAllowed(agentGrant));
    }

    /// The one difference: an ID with no grant yet has no `setCaps`, and only the top principal may write its entries.
    function test_review_entriesForAnIdWithNoGrant_onlyTheTopPrincipalWrites() public {
        uint256 future = uint256(keccak256(abi.encode(agentGrant, sub, bytes32("review"))));
        bytes32 m = _merchant();
        vm.prank(buyer);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, future, m, true, "");
        vm.prank(principal);
        allowList.set(vault, future, m, true, "");
        assertTrue(allowList.allowed(address(vault), future, m));
    }

    // Q1 to Q3: a slip that names a list

    /// A slip from the agent that names the default list lands with no entries: the agent cannot write the entries of
    /// a grant that does not exist yet, so its sub-agent pays no one until the agent sends a transaction.
    function test_review_aSlipNamingTheDefaultList_landsEmpty_untilItsSignerWrites() public {
        ICrestVault.SignedGrant memory s = _slip(address(allowList));
        uint256 id = uint256(keccak256(abi.encode(s.parent, s.controller, s.salt)));
        bytes32 m = _merchant();
        vm.prank(buyer);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, id, m, true, "before the slip lands");
        vault.grantBySig(s, _slipSig(BUYER_PK, vault, s));
        _expectRefused(_vterms(address(vault), sub), SUB_PK, _notAllowed(id));
        vm.prank(buyer);
        allowList.set(vault, id, m, true, "after it lands");
        _fundVia(_vterms(address(vault), sub), SUB_PK);
    }

    /// A slip names a third party's list, which later says yes to everyone. The sub-agent still pays only inside the
    /// agent's own list, as it would if the signer had pointed the grant at no list by transaction, and a stop above
    /// still stops it.
    function test_review_aThirdPartyListOnASlip_widensNothingPastTheSignersPath() public {
        OwnedList other = new OwnedList(stranger);
        ICrestVault.SignedGrant memory s = _slip(address(other));
        uint256 id = vault.grantBySig(s, _slipSig(BUYER_PK, vault, s));
        H.Terms memory far = _vterms(address(vault), sub);
        far.sellerPayoutAddress = makeAddr("unlisted payout");

        _expectRefused(_vterms(address(vault), sub), SUB_PK, _notAllowed(id));
        vm.prank(stranger);
        other.setYesToAll(true);
        _expectRefused(far, SUB_PK, _notAllowed(agentGrant));

        ICrestVault.Caps memory none = s.caps;
        none.list = address(0);
        uint256 snap = vm.snapshotState();
        vm.prank(buyer);
        vault.setCaps(id, none, "the signer's own widest choice");
        _expectRefused(far, SUB_PK, _notAllowed(agentGrant));
        vm.revertToState(snap);

        _fundVia(_vterms(address(vault), sub), SUB_PK);
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "");
        _expectRefused(
            _vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant)
        );
        vm.prank(principal);
        vault.close(agentGrant, "");
        _expectRefused(
            _vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant)
        );
    }

    // Q4: the cap

    /// The largest list that fits the cap pays; one loop round more is refused and nothing is counted.
    function test_review_aListAtTheCap_pays_andOneRoundMore_isRefused() public {
        uint256 lo = 0;
        uint256 hi = 4_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            (bool yes,) = probe.ask(address(new RoundsList(mid)), LIST_GAS, address(vault), agentGrant, 0);
            if (yes) lo = mid;
            else hi = mid;
        }
        RoundsList fits = new RoundsList(lo);
        RoundsList over = new RoundsList(lo + 1);
        uint256 needFits = _leastGasForYes(address(fits), address(0));
        uint256 needOver = _leastGasForYes(address(over), address(0));
        emit log_named_uint("rounds that fit the cap", lo);
        emit log_named_uint("gas the largest fitting list needs", needFits);
        emit log_named_uint("gas one round more needs", needOver);
        assertLe(needFits, LIST_GAS);
        assertGt(needOver, LIST_GAS);

        _point(agentGrant, address(over));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _notAllowed(agentGrant));
        assertEq(_grantOf(vault, agentGrant).spent, 0);
        assertEq(_grantOf(vault, agentGrant).open, 0);
        _point(agentGrant, address(fits));
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        assertEq(_grantOf(vault, agentGrant).spent, HOLD);
    }

    // The 63/64 rule: the submitter picks the transaction's gas

    /// `checkPath` asked with little gas can no longer flip a list whose answer depends on its gas: a call that could
    /// not give the list its whole cap is refused.
    function test_review_aStarvedList_neverFlipsCheckPath() public {
        StarvedList l = new StarvedList();
        _point(agentGrant, address(l));
        bytes32 far = keccak256("unlisted");
        vm.expectRevert(_notAllowed(agentGrant));
        vault.checkPath(agentGrant, HOLD, far);
        uint256 flippedAt;
        for (uint256 g = 3_000; g < 120_000; g += 25) {
            (bool ok,) = address(vault).staticcall{gas: g}(abi.encodeCall(vault.checkPath, (agentGrant, HOLD, far)));
            if (ok) {
                flippedAt = g;
                break;
            }
        }
        assertEq(flippedAt, 0, "a gas budget flipped the answer");
    }

    /// The same list never lets a payment through, whatever gas the transaction carries: the vault and the module
    /// need more gas after the question than a starved frame keeps.
    function test_review_aStarvedList_neverPassesAPayment() public {
        StarvedList l = new StarvedList();
        _point(agentGrant, address(l));
        H.Terms memory t = _unlisted();
        bytes memory data = abi.encodeCall(
            module.agreeAndFund,
            (
                t,
                _sellerSig(t, SELLER_PK),
                _acceptance(t, ADJ_PK),
                _agree(t, BUYER_PK),
                H.Funding({signature: new bytes(65)})
            )
        );
        uint256 passedAt;
        for (uint256 g = 5_000; g < 700_000; g += 997) {
            (bool ok,) = address(module).call{gas: g}(data);
            if (ok) {
                passedAt = g;
                break;
            }
        }
        assertEq(passedAt, 0, "a starved list passed a payment");
        // Since the gas floor, a list the vault cannot give its whole cap is never asked: the payment is refused with
        // `ListGasTooLow` first.
    }

    /// The same through a child vault, where the parent's list is asked from `checkPath`.
    function test_review_aStarvedParentList_neverPassesAChildsPayment() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vm.prank(buyer);
        vault.fundChild(address(child), 2 * HOLD, "");
        vm.prank(buyer);
        child.grant(ROOT, sub, _wide(), 0, "");
        StarvedList l = new StarvedList();
        _point(agentGrant, address(l));
        H.Terms memory t = _vterms(address(child), sub);
        t.sellerPayoutAddress = makeAddr("unlisted payout");
        bytes memory data = abi.encodeCall(
            module.agreeAndFund,
            (
                t,
                _sellerSig(t, SELLER_PK),
                _acceptance(t, ADJ_PK),
                _agree(t, SUB_PK),
                H.Funding({signature: new bytes(65)})
            )
        );
        uint256 passedAt;
        for (uint256 g = 60_000; g < 800_000; g += 997) {
            (bool ok,) = address(module).call{gas: g}(data);
            if (ok) {
                passedAt = g;
                break;
            }
        }
        assertEq(passedAt, 0, "a starved parent list passed a child's payment");
        // Since the gas floor, a list the vault cannot give its whole cap is never asked: the payment is refused with
        // `ListGasTooLow` first.
    }

    // The answer's encoding

    function test_review_aRevertCarryingTheMagic_isANo() public {
        _point(agentGrant, address(new RawList(0, 0)));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _notAllowed(agentGrant));
    }

    function test_review_aFourByteMagic_isANo() public {
        _point(agentGrant, address(new RawList(1, 0)));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _notAllowed(agentGrant));
    }

    function test_review_aLongAnswerThatStartsWithTheMagic_isANo() public {
        RawList l = new RawList(2, 0);
        (, uint256 length) = probe.ask(address(l), LIST_GAS, address(vault), agentGrant, 0);
        assertEq(length, 64, "the list answered within the cap");
        _point(agentGrant, address(l));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _notAllowed(agentGrant));
    }

    function test_review_theMagicWithADirtyLowByte_isANo() public {
        _point(agentGrant, address(new RawList(3, 0)));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _notAllowed(agentGrant));
    }

    /// The PR's `Huge` mode answers 100,000 bytes within the cap, but its first word is 0x5b2f3f0e, not the selector of
    /// `allows` (0xe2d832de). So the selector check refuses it, and no PR test reaches the length check.
    /// The cap bounds the list's own gas, not the vault's copy of its answer: the largest answer a list can afford
    /// under the cap costs the vault this much more than a plain no. It is always a no.
    function test_review_aLongAnswer_costsTheVaultPastTheCap() public {
        uint256 lo = 32;
        uint256 hi = 400_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            (, uint256 length) = probe.ask(address(new RawList(9, mid)), LIST_GAS, address(vault), agentGrant, 0);
            if (length == mid) lo = mid;
            else hi = mid;
        }
        emit log_named_uint("the longest answer a list affords under the cap, bytes", lo);
        RawList bomb = new RawList(9, lo);
        RawList plainNo = new RawList(5, 0);
        bytes memory ask = abi.encodeCall(vault.checkPath, (agentGrant, HOLD, _merchant()));

        _point(agentGrant, address(plainNo));
        uint256 g = gasleft();
        (bool ok,) = address(vault).staticcall(ask);
        uint256 noCost = g - gasleft();
        assertFalse(ok);
        _point(agentGrant, address(bomb));
        g = gasleft();
        (ok,) = address(vault).staticcall(ask);
        uint256 bombCost = g - gasleft();
        assertFalse(ok);
        emit log_named_uint("checkPath with a plain no, gas", noCost);
        emit log_named_uint("checkPath with the longest answer, gas", bombCost);
        emit log_named_uint("the vault's extra gas past the cap", bombCost - noCost);
    }

    // Writes and re-entry

    /// A list that writes is refused because the vault asks by `staticcall`, not because of the list's own code.
    function test_review_aListThatWrites_isRefusedByTheStaticcall() public {
        WritingList w = new WritingList();
        assertEq(
            w.allows(address(vault), agentGrant, 0), ICrestList.allows.selector, "outside a static call it says yes"
        );
        _point(agentGrant, address(w));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _notAllowed(agentGrant));
        assertEq(w.writes(), 1, "only the direct call wrote");
    }

    /// A list with authority above the grant it is asked about tries to widen that grant while it answers. The write
    /// fails inside the vault's static call; the same call outside it goes through.
    function test_review_aListWithAuthority_cannotWriteWhileItAnswers() public {
        ReenteringList r = new ReenteringList();
        vm.startPrank(principal);
        uint256 above = vault.grant(ROOT, address(r), _wide(), 0, "");
        ICrestVault.Caps memory c = _caps(HOLD, 3 * HOLD, type(uint128).max, 2, false, false);
        c.list = address(r);
        uint256 asked = vault.grant(above, sub, c, 0, "");
        vm.stopPrank();
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        assertEq(_grantOf(vault, asked).caps.list, address(r), "the list widened the grant while it answered");
        (bool ok,) = address(r).call{gas: 25_000}(abi.encodeCall(r.widen, (address(vault), asked)));
        assertTrue(ok, "the same write, with the same gas, outside a static call");
        assertEq(_grantOf(vault, asked).caps.list, address(0), "the same write outside a static call went through");
    }

    // Q5: no code, self-destruct, proxies

    function test_review_aListWithNoCode_refuses() public {
        _point(agentGrant, makeAddr("no code here"));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _notAllowed(agentGrant));
        _point(agentGrant, address(0x4));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _notAllowed(agentGrant));
    }

    /// Since EIP-6780 a list made in an earlier transaction keeps its code after SELFDESTRUCT and keeps answering.
    /// With its code gone (as `vm.etch` shows), the vault refuses.
    function test_review_aSelfDestructedList_keepsAnswering_andNoCodeRefuses() public {
        _point(agentGrant, address(doomed));
        doomed.destroy();
        assertGt(address(doomed).code.length, 0);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        vm.etch(address(doomed), "");
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _notAllowed(agentGrant));
    }

    /// A proxy's admin decides whom the grant may pay, at payment time, and still only inside every list above.
    function test_review_aSwappedProxyList_paymentTimeDecides_insideTheListsAbove() public {
        YesImpl yes = new YesImpl();
        NoImpl no = new NoImpl();
        vm.prank(stranger);
        SwapProxyList p = new SwapProxyList(address(yes));
        _point(agentGrant, address(p));
        assertEq(ICrestList(address(p)).allows(address(vault), agentGrant, 0), ICrestList.allows.selector);
        vm.prank(stranger);
        p.swap(address(no));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _notAllowed(agentGrant));
        vm.prank(stranger);
        p.swap(address(yes));
        _fundVia(_unlisted(), BUYER_PK);

        _point(agentGrant, address(allowList));
        vm.prank(buyer);
        vault.grant(agentGrant, sub, _caps(HOLD, 3 * HOLD, type(uint128).max, 2, false, false), 0, "");
        uint256 subGrant = vault.grantOf(sub);
        _point(subGrant, address(p));
        H.Terms memory t = _vterms(address(vault), sub);
        t.sellerPayoutAddress = makeAddr("unlisted payout");
        _expectRefused(t, SUB_PK, _notAllowed(agentGrant));
    }

    /// The pointer swapped between a simulation and the payment: the pointer at payment time decides.
    function test_review_thePointerSwappedAfterASimulation_paymentTimeDecides() public {
        vault.checkPath(agentGrant, HOLD, _merchant());
        _point(agentGrant, address(new NoImpl()));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _notAllowed(agentGrant));
    }
}

/// Gas of a funding three grants deep, each grant naming the default list with the merchant listed, and the same
/// path with no list anywhere. Grants are made in `setUp`, so each funding starts cold.
contract ListReviewThreeLevelGasTest is CrestBase {
    uint256 internal subGrant;
    uint256 internal subSub;

    function setUp() public override {
        super.setUp();
        vm.prank(buyer);
        subGrant = vault.grant(agentGrant, sub, _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, true), 0, "");
        vm.prank(sub);
        subSub = vault.grant(subGrant, sub2, _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, false), 0, "");
        vm.startPrank(principal);
        allowList.set(vault, subGrant, _merchant(), true, "");
        allowList.set(vault, subSub, _merchant(), true, "");
        vm.stopPrank();
    }

    function _funding(address key, uint256 pk) internal returns (uint256 used) {
        H.Terms memory t = _vterms(address(vault), key);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, pk);
        uint256 before = gasleft();
        module.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)}));
        used = before - gasleft();
    }

    function test_gas_review_threeLevelsEachWithTheDefaultList() public {
        emit log_named_uint("three levels, each with the default list, execution gas", _funding(sub2, SUB2_PK));
    }
}

contract ListReviewNoListGasTest is CrestBase {
    function setUp() public override {
        super.setUp();
        ICrestVault.Caps memory c = _caps(HOLD, 3 * HOLD, type(uint128).max, 2, false, true);
        vm.prank(principal);
        vault.setCaps(agentGrant, c, "");
    }

    function test_gas_review_oneLevelNoList() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, BUYER_PK);
        uint256 before = gasleft();
        module.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)}));
        emit log_named_uint("one level, no list, execution gas", before - gasleft());
    }
}

/// The gas each list uses inside the vault's call with its storage cold: its first call's cost against the first call
/// of a list with no storage that answers at once, plus that list's own need. Everything is built in `setUp`, so the
/// test starts cold, and every list account is cold at its first call, so the account cost cancels.
contract ListReviewColdCapTest is CrestBase {
    ReviewProbe internal probe;
    ReviewRegistry internal registry;
    ReviewRegistryList internal byRegistry;
    YesImpl internal instant;
    YesImpl internal warmUp;

    function setUp() public override {
        super.setUp();
        probe = new ReviewProbe();
        registry = new ReviewRegistry();
        registry.register(_merchant(), makeAddr("the merchant's owner"));
        byRegistry = new ReviewRegistryList(registry);
        instant = new YesImpl();
        warmUp = new YesImpl();
    }

    function _outer(address list, bytes32 cp) internal view returns (uint256 used) {
        uint256 before = gasleft();
        (bool yes,) = probe.ask(list, 30_000, address(vault), agentGrant, cp);
        used = before - gasleft();
        require(yes, "the list said no");
    }

    function test_review_theCap_againstEachListsColdGas() public {
        bytes32 m = _merchant();
        _outer(address(warmUp), m);
        uint256 base = _outer(address(instant), m);
        uint256 own = _outer(address(allowList), m);
        uint256 reg = _outer(address(byRegistry), m);
        uint256 lo = 0;
        uint256 hi = 30_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            (bool yes,) = probe.ask(address(instant), mid, address(vault), agentGrant, m);
            if (yes) hi = mid;
            else lo = mid;
        }
        emit log_named_uint("an instant list's own need, gas", hi);
        emit log_named_uint("the default list, cold, gas inside the call", own - base + hi);
        emit log_named_uint("the registry-reading list, cold, gas inside the call", reg - base + hi);
        assertLt(reg - base + hi, 30_000);
    }
}
