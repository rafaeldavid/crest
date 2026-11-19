// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../src/CrestVault.sol";
import {ICrestVault} from "../src/ICrestVault.sol";
import {CrestBase} from "./CrestBase.sol";

/// A contract that controls a grant and would answer ERC-1271 to anyone: slips are ECDSA only, so it is never asked.
contract ContractController {
    uint256 public asked;

    function isValidSignature(bytes32, bytes calldata) external returns (bytes4) {
        asked++;
        return 0x1626ba7e;
    }
}

/// Grants by a signature alone: the controller of a grant that may delegate signs a `SignedGrant` off chain, anyone
/// submits it, and it lands as an ordinary grant for the key it names. Each `test_attack_*` passes when the defence
/// holds.
contract SignedGrantTest is CrestBase {
    bytes32 internal constant CAPS_TYPEHASH = keccak256(
        "Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool restricted,bool mayDelegate)"
    );
    bytes32 internal constant SIGNED_GRANT_TYPEHASH = keccak256(
        "SignedGrant(uint256 parent,address controller,Caps caps,bytes32 salt,bytes32[] counterparties,uint40 deadline,bytes note)Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool restricted,bool mayDelegate)"
    );
    uint256 internal constant N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
    uint256 internal constant STRANGER_PK = 0x5778;

    function _domain(CrestVault v) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Crest"),
                keccak256("1"),
                block.chainid,
                address(v)
            )
        );
    }

    function _digest(CrestVault v, ICrestVault.SignedGrant memory s) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNED_GRANT_TYPEHASH,
                s.parent,
                s.controller,
                keccak256(abi.encode(CAPS_TYPEHASH, s.caps)),
                s.salt,
                keccak256(abi.encodePacked(s.counterparties)),
                s.deadline,
                keccak256(s.note)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domain(v), structHash));
    }

    function _signed(uint256 pk, CrestVault v, ICrestVault.SignedGrant memory s) internal view returns (bytes memory) {
        (uint8 sv, bytes32 r, bytes32 ss) = vm.sign(pk, _digest(v, s));
        return abi.encodePacked(r, ss, sv);
    }

    /// The agent (Holdback's `buyer` key) gives its sub-agent `sub` one deal at a time, two holds a day, the test
    /// merchant only, and no right to delegate.
    function _slip() internal view returns (ICrestVault.SignedGrant memory s) {
        bytes32[] memory merchants = new bytes32[](1);
        merchants[0] = _merchant();
        s = ICrestVault.SignedGrant({
            parent: agentGrant,
            controller: sub,
            caps: _caps(HOLD, 2 * HOLD, type(uint128).max, 1, true, false),
            salt: bytes32("one task"),
            counterparties: merchants,
            deadline: uint40(vm.getBlockTimestamp() + 1 hours),
            note: "a sub-agent for one task"
        });
    }

    function _idOf(ICrestVault.SignedGrant memory s) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(s.parent, s.controller, s.salt)));
    }

    // It lands as an ordinary grant

    function test_aSignedGrantLands_asAnOrdinaryGrant_andTheNamedKeyPays() public {
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory sig = _signed(BUYER_PK, vault, s);
        uint256 id = _idOf(s);
        vm.expectEmit(address(vault));
        emit ICrestVault.Granted(id, agentGrant, sub, s.caps, buyer, s.note);
        vm.expectEmit(address(vault));
        emit ICrestVault.Allowed(id, _merchant(), true, buyer, s.note);
        vm.prank(stranger);
        assertEq(vault.grantBySig(s, sig), id);
        assertEq(vault.grantOf(sub), id);
        assertTrue(vault.allowed(id, _merchant()));
        bytes32 deal = _fundVia(_vterms(address(vault), sub), SUB_PK);
        assertEq(uint8(_stage(deal)), uint8(IHoldbackRules.Stage.Held));
        assertEq(_grantOf(vault, id).spent, HOLD);
        assertEq(_grantOf(vault, agentGrant).spent, HOLD, "the signer's grant counts the sub-agent's spend");
    }

    function test_theTopPrincipalSignsUnderTheRoot() public {
        ICrestVault.SignedGrant memory s = _slip();
        s.parent = ROOT;
        vault.grantBySig(s, _signed(PRINCIPAL_PK, vault, s));
        assertEq(_grantOf(vault, vault.grantOf(sub)).parent, ROOT);
    }

    // Not a bearer instrument

    /// Whoever submits the slip gains nothing: the grant is the named key's, and a holder of the slip without that key
    /// cannot pay through it.
    function test_attack_aHolderOfTheSlipWithoutTheKeyPays_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        vm.prank(stranger);
        vault.grantBySig(s, _signed(BUYER_PK, vault, s));
        assertEq(vault.grantOf(stranger), 0, "the submitter holds no grant");
        _expectRefused(
            _vterms(address(vault), stranger), STRANGER_PK, abi.encodeWithSelector(ICrestVault.NoGrant.selector)
        );
        H.Terms memory t = _vterms(address(vault), sub);
        bytes memory sellerSig = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory forged = _agree(t, STRANGER_PK);
        vm.expectRevert();
        module.agreeAndFund(t, sellerSig, a, forged, H.Funding({signature: new bytes(65)}));
        assertEq(_grantOf(vault, _idOf(s)).spent, 0);
    }

    // Cancelling an unused slip

    function test_cancel_anUnusedSlip_thenItsSubmissionIsRefused() public {
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory sig = _signed(BUYER_PK, vault, s);
        vm.expectEmit(address(vault));
        emit ICrestVault.Closed(_idOf(s), buyer, "no longer needed");
        vm.prank(buyer);
        vault.cancelSignedGrant(s.parent, s.controller, s.salt, "no longer needed");
        vm.prank(stranger);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.grantBySig(s, sig);
        assertEq(vault.grantOf(sub), 0);
    }

    function test_cancel_byAuthorityAbove_andByNoOneElse() public {
        ICrestVault.SignedGrant memory s = _slip();
        vm.prank(stranger);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.cancelSignedGrant(s.parent, s.controller, s.salt, "");
        vm.prank(principal);
        vault.cancelSignedGrant(s.parent, s.controller, s.salt, "the principal voids it");
        assertTrue(_grantOf(vault, _idOf(s)).closed);
    }

    function test_cancel_aUsedSlip_refused_closeTheGrantInstead() public {
        ICrestVault.SignedGrant memory s = _slip();
        vault.grantBySig(s, _signed(BUYER_PK, vault, s));
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.cancelSignedGrant(s.parent, s.controller, s.salt, "");
        vm.prank(buyer);
        vault.close(_idOf(s), "the task is done");
        _expectRefused(_vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.NoGrant.selector));
    }

    // Replays

    function test_attack_aSecondSubmission_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory sig = _signed(BUYER_PK, vault, s);
        vault.grantBySig(s, sig);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.grantBySig(s, sig);
    }

    function test_attack_aReplayAfterTheGrantClosed_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory sig = _signed(BUYER_PK, vault, s);
        vault.grantBySig(s, sig);
        vm.prank(buyer);
        vault.close(_idOf(s), "");
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.grantBySig(s, sig);
    }

    /// The same agent holds the same grant ID in a second vault of the same principal; the slip signed for the first
    /// still recovers to no one with authority in the second.
    function test_attack_aReplayOnAnotherVault_refused() public {
        CrestVault other = CrestVault(factory.create(principal, address(usdc), bytes32("another vault")));
        vm.prank(principal);
        assertEq(other.grant(ROOT, buyer, _wide(), 0, ""), agentGrant, "the same grant ID in the other vault");
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory sig = _signed(BUYER_PK, vault, s);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        other.grantBySig(s, sig);
    }

    function test_attack_aReplayOnAnotherChain_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory sig = _signed(BUYER_PK, vault, s);
        vm.chainId(11_155_111);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(s, sig);
    }

    function test_attack_afterTheDeadline_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory sig = _signed(BUYER_PK, vault, s);
        vm.warp(uint256(s.deadline) + 1);
        vm.expectRevert(ICrestVault.SignedGrantExpired.selector);
        vault.grantBySig(s, sig);
    }

    /// Every field is signed: changing any one after signing recovers another signer, which has no authority.
    function test_attack_aFieldChangedAfterSigning_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory sig = _signed(BUYER_PK, vault, s);
        for (uint256 i; i < 7; i++) {
            ICrestVault.SignedGrant memory m = _slip();
            if (i == 0) m.parent = ROOT;
            if (i == 1) m.controller = sub2;
            if (i == 2) m.caps.perSpend += 1;
            if (i == 3) m.salt = bytes32("another task");
            if (i == 4) m.counterparties[0] = keccak256("another merchant");
            if (i == 5) m.deadline += 1;
            if (i == 6) m.note = "another note";
            vm.expectRevert(ICrestVault.NotAuthorized.selector);
            vault.grantBySig(m, sig);
        }
        vault.grantBySig(s, sig);
    }

    // Who may sign

    function test_attack_aSignerWithNoAuthority_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(s, _signed(STRANGER_PK, vault, s));
    }

    function test_attack_aClosedGrantsKeySigns_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory sig = _signed(BUYER_PK, vault, s);
        vm.prank(principal);
        vault.close(agentGrant, "");
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant));
        vault.grantBySig(s, sig);
    }

    function test_attack_aPausedSignersSlip_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory sig = _signed(BUYER_PK, vault, s);
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "");
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant));
        vault.grantBySig(s, sig);
    }

    function test_attack_aGrantThatMayNotDelegateSigns_refused() public {
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, false));
        ICrestVault.SignedGrant memory s = _slip();
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grantBySig(s, _signed(BUYER_PK, vault, s));
    }

    /// A sub-agent's slip under its own parent needs delegation on the whole path, as a grant by transaction does.
    function test_attack_aSubAgentSignsBelowAnAgentThatMayNotDelegate_refused() public {
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _wide(), 0, "");
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, false));
        ICrestVault.SignedGrant memory s = _slip();
        (s.parent, s.controller) = (subGrant, sub2);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grantBySig(s, _signed(SUB_PK, vault, s));
    }

    function test_attack_aSignedGrantTakesAKeyHeldElsewhere_refused() public {
        address other = makeAddr("another agent");
        vm.prank(principal);
        uint256 otherGrant = vault.grant(ROOT, other, _wide(), bytes32("other"), "");
        ICrestVault.SignedGrant memory s = _slip();
        s.controller = other;
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.grantBySig(s, _signed(BUYER_PK, vault, s));
        assertEq(vault.grantOf(other), otherGrant);
    }

    // Limits

    function test_attack_limitsWiderThanTheParent_payNoMoreThanTheParentAllows() public {
        ICrestVault.SignedGrant memory s = _slip();
        s.caps = _wide();
        vault.grantBySig(s, _signed(BUYER_PK, vault, s));
        H.Terms memory t = _vterms(address(vault), sub);
        t.price = PRICE + 1;
        _expectRefused(t, SUB_PK, abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, agentGrant));
    }

    function test_aSlipSubmittedBeforeAStop_givesAGrantTheStopReaches() public {
        ICrestVault.SignedGrant memory s = _slip();
        vault.grantBySig(s, _signed(BUYER_PK, vault, s));
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop the agent and all below it");
        _expectRefused(
            _vterms(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant)
        );
    }

    function test_attack_aZeroKeyOrAZeroPeriod_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        s.controller = address(0);
        vm.expectRevert(ICrestVault.ZeroAddress.selector);
        vault.grantBySig(s, _signed(BUYER_PK, vault, s));
        s = _slip();
        s.caps.period = 0;
        vm.expectRevert(ICrestVault.InvalidCaps.selector);
        vault.grantBySig(s, _signed(BUYER_PK, vault, s));
    }

    // Signatures

    function test_attack_aMalleableSignature_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(BUYER_PK, _digest(vault, s));
        bytes memory twin = abi.encodePacked(r, bytes32(N - uint256(ss)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(ICrestVault.BadSignature.selector);
        vault.grantBySig(s, twin);
        vault.grantBySig(s, abi.encodePacked(r, ss, v));
        vm.expectRevert(ICrestVault.BadSignature.selector);
        vault.grantBySig(s, twin);
    }

    function test_attack_aWrongLengthSignature_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(BUYER_PK, _digest(vault, s));
        bytes32 vs = bytes32(uint256(ss) | (uint256(v - 27) << 255));
        vm.expectRevert(ICrestVault.BadSignature.selector);
        vault.grantBySig(s, abi.encodePacked(r, vs));
        vm.expectRevert(ICrestVault.BadSignature.selector);
        vault.grantBySig(s, abi.encodePacked(r, ss, v, uint8(0)));
        vm.expectRevert(ICrestVault.BadSignature.selector);
        vault.grantBySig(s, "");
    }

    /// Slips are ECDSA only. A contract that controls a grant grants by transaction: the vault never asks it by
    /// ERC-1271, and no signature makes a slip under its grant.
    function test_attack_aContractSigner_refusedByName() public {
        ContractController c = new ContractController();
        vm.prank(principal);
        uint256 cGrant = vault.grant(ROOT, address(c), _wide(), bytes32("a contract"), "");
        ICrestVault.SignedGrant memory s = _slip();
        s.parent = cGrant;
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(s, _signed(STRANGER_PK, vault, s));
        assertEq(c.asked(), 0, "the vault never asked the contract");
        vm.prank(address(c));
        vault.grant(cGrant, sub, _wide(), bytes32("by transaction"), "");
    }

    function test_theDomainIsThisVaultOnThisChain() public view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            vault.eip712Domain();
        assertEq(name, "Crest");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(vault));
    }

    // Gas: the same grant, with one listed counterparty, by a signature and by transactions, each from cold storage.
    // Each logs its execution gas and its calldata gas, which a transaction adds to its 21,000 base.

    function _calldataGas(bytes memory data) internal pure returns (uint256 gas) {
        for (uint256 i; i < data.length; ++i) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    function test_gas_aSignedGrant() public {
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory sig = _signed(BUYER_PK, vault, s);
        bytes memory data = abi.encodeCall(vault.grantBySig, (s, sig));
        uint256 before = gasleft();
        vault.grantBySig(s, sig);
        emit log_named_uint("grantBySig, execution gas", before - gasleft());
        emit log_named_uint("grantBySig, calldata gas", _calldataGas(data));
    }

    function test_gas_aGrantThenAnAllowByTransaction() public {
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory grantData = abi.encodeCall(vault.grant, (s.parent, s.controller, s.caps, s.salt, s.note));
        uint256 id = _idOf(s);
        bytes32 merchant = _merchant();
        bytes memory allowData = abi.encodeCall(vault.allow, (id, merchant, true, s.note));
        vm.prank(buyer);
        uint256 before = gasleft();
        vault.grant(s.parent, s.controller, s.caps, s.salt, s.note);
        emit log_named_uint("grant, execution gas", before - gasleft());
        vm.prank(buyer);
        before = gasleft();
        vault.allow(id, merchant, true, s.note);
        emit log_named_uint("allow, execution gas", before - gasleft());
        emit log_named_uint("grant, calldata gas", _calldataGas(grantData));
        emit log_named_uint("allow, calldata gas", _calldataGas(allowData));
    }
}
