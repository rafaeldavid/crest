// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {LibClone} from "solady/utils/LibClone.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {RedTeamBase} from "../redteam/RedTeamBase.sol";

/// Classes from the published audits that no other Crest test names. Each passes: the class is covered, and this is the
/// test that shows it.
contract CrossCheckCoverageTest is RedTeamBase {
    bytes32 internal constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant N = keccak256("cross-check nonce");

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
    }

    /// ERC-3009 and EIP-2612: within the transaction of a charge, the vault answers the token only for the
    /// `ReceiveWithAuthorization` it built. A `TransferWithAuthorization` (which anyone may submit), a
    /// `CancelAuthorization` (which would let anyone burn the vault's nonce) and a `Permit` over the same values all get
    /// no.
    function test_defense_duringACharge_noTransferCancelOrPermitDigestIsApproved() public {
        vm.prank(principal);
        vault.setModule(address(this), address(this), "");
        uint256 validBefore = block.timestamp + 1 hours;
        vault.charge(buyer, HOLD, _merchant(), keccak256("cross-check commitment"), validBefore, N);
        bytes32 receive_ = _digest(
            keccak256(
                abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, address(vault), address(this), HOLD, 0, validBefore, N)
            )
        );
        bytes32 transfer_ = _digest(
            keccak256(
                abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, address(vault), address(this), HOLD, 0, validBefore, N)
            )
        );
        bytes32 cancel_ = _digest(keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, address(vault), N)));
        bytes32 permit_ =
            _digest(keccak256(abi.encode(PERMIT_TYPEHASH, address(vault), address(this), HOLD, 0, validBefore)));
        vm.startPrank(address(usdc));
        assertEq(vault.isValidSignature(receive_, ""), MAGIC_1271, "the approved receive");
        assertEq(vault.isValidSignature(transfer_, ""), NO_1271, "a transfer authorization");
        assertEq(vault.isValidSignature(cancel_, ""), NO_1271, "a cancel authorization");
        assertEq(vault.isValidSignature(permit_, ""), NO_1271, "a permit");
        vm.stopPrank();
    }

    /// Observation (design, documented in ICrestVault): a parent grant's open-commitment limit does not bound the
    /// commitments of a child vault it fills. The child's root starts with no limits; only the principal's own setting
    /// on the child's root bounds them.
    function test_observe_aParentGrantsOpenLimit_doesNotBoundItsChildVault() public {
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 1, true, true));
        (CrestVault child, uint256 subInChild) = _agentChild(3 * HOLD);
        _fundVia(_vterms(address(child), sub), SUB_PK);
        _fundVia(_vterms(address(child), sub), SUB_PK);
        _fundVia(_vterms(address(child), sub), SUB_PK);
        assertEq(_grantOf(child, subInChild).open, 3, "three open from the child");
        assertEq(_grantOf(vault, agentGrant).open, 0, "the agent's grant, limited to 1 open, counts none of them");
    }

    /// Close is terminal for payments, but not for management (the capped minters' I-02 class): limits and lists of a
    /// closed grant can still be changed and each change emits an event. Harmless: a closed grant never pays.
    function test_observe_aClosedGrantsLimitsAndListStillChange_butItNeverPays() public {
        vm.startPrank(principal);
        vault.close(agentGrant, "");
        vault.setCaps(agentGrant, _wide(), "after close");
        allowList.set(vault, agentGrant, keccak256("anyone"), true, "after close");
        vault.setPaused(agentGrant, false, "after close");
        vm.stopPrank();
        assertTrue(_grantOf(vault, agentGrant).closed);
        assertEq(vault.grantOf(buyer), 0, "the key is free, so the closed grant cannot be charged");
    }
}

/// The interface says "No upgrade, no delegatecall, no selfdestruct". Walks the deployed code of the vault
/// implementation, the factory and the Holdback module, skipping PUSH data and the compiler's metadata, and checks a
/// vault is exactly the library's minimal proxy for the factory's implementation.
contract CrossCheckOpcodesTest is RedTeamBase {
    function _count(bytes memory code, uint8 op) internal pure returns (uint256 n) {
        uint256 end = code.length;
        if (end >= 2) {
            uint256 meta = (uint256(uint8(code[end - 2])) << 8) | uint8(code[end - 1]);
            if (meta + 2 <= end) end -= meta + 2;
        }
        for (uint256 i; i < end; i++) {
            uint8 b = uint8(code[i]);
            if (b == op) n++;
            if (b >= 0x60 && b <= 0x7f) i += b - 0x5f;
        }
    }

    function test_defense_noSelfdestructCallcodeOrDelegatecall_inTheVaultFactoryOrModule() public view {
        address[3] memory targets = [factory.IMPLEMENTATION(), address(factory), address(module)];
        for (uint256 i; i < targets.length; i++) {
            bytes memory code = targets[i].code;
            assertEq(_count(code, 0xff), 0, "SELFDESTRUCT");
            assertEq(_count(code, 0xf2), 0, "CALLCODE");
            assertEq(_count(code, 0xf4), 0, "DELEGATECALL");
        }
    }

    /// Zero arguments (the capped minters' zero-admin class): a vault with no principal or no token, and a grant to
    /// key 0, are refused.
    function test_defense_zeroPrincipalTokenOrControllerRefused() public {
        vm.expectRevert(ICrestVault.ZeroAddress.selector);
        factory.create(address(0), address(usdc), bytes32("zero"));
        vm.expectRevert(ICrestVault.ZeroAddress.selector);
        factory.create(principal, address(0), bytes32("zero"));
        vm.prank(principal);
        vm.expectRevert(ICrestVault.ZeroAddress.selector);
        vault.grant(ROOT, address(0), _wide(), bytes32("zero"), "");
    }

    function test_defense_aVaultIsExactlyTheMinimalProxyForTheImplementation() public {
        address reference_ = LibClone.clone(factory.IMPLEMENTATION());
        assertEq(keccak256(address(vault).code), keccak256(reference_.code), "the vault's runtime code");
        assertEq(_count(address(vault).code, 0xf4), 1, "one DELEGATECALL, to the fixed implementation");
    }
}
