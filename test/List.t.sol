// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestAllowList} from "../src/CrestAllowList.sol";
import {CrestVault} from "../src/CrestVault.sol";
import {ICrestAllowList} from "../src/ICrestAllowList.sol";
import {ICrestList, ICrestVault} from "../src/ICrestVault.sol";
import {CrestBase} from "./CrestBase.sol";

/// A list whose answer the test sets: yes, no, or a misbehaviour.
contract ScriptedList {
    enum Mode {
        Yes,
        No,
        Revert,
        Loop,
        TrueNotMagic,
        Garbage,
        Huge,
        Write,
        Reenter
    }

    Mode public mode;
    uint256 public writes;

    function set(Mode m) external {
        mode = m;
    }

    function allows(address vault, uint256 grant, bytes32) external view returns (bytes4) {
        Mode m = mode;
        if (m == Mode.Yes) return ICrestList.allows.selector;
        if (m == Mode.Revert) revert("no");
        if (m == Mode.Loop) {
            uint256 x;
            while (true) {
                x++;
            }
        }
        if (m == Mode.TrueNotMagic) {
            assembly {
                mstore(0, 1)
                return(0, 32)
            }
        }
        if (m == Mode.Garbage) {
            assembly {
                mstore(0, 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20)
                return(0, 32)
            }
        }
        if (m == Mode.Huge) {
            assembly {
                mstore(0, shl(224, 0xe2d832de))
                return(0, 100000)
            }
        }
        if (m == Mode.Write) {
            (bool ok,) = address(this).staticcall(abi.encodeWithSignature("bump()"));
            return ok ? ICrestList.allows.selector : bytes4(0);
        }
        if (m == Mode.Reenter) {
            ICrestVault(vault).checkPath(grant, 1, bytes32(0));
            return ICrestList.allows.selector;
        }
        return bytes4(0);
    }

    function bump() external {
        writes++;
    }
}

/// A list that asks another contract, as an identity-based list would ask a registry: one cold call and two cold reads.
contract Registry {
    mapping(bytes32 => address) public ownerOf;
    mapping(address => bool) public inGoodStanding;

    function register(bytes32 who, address owner) external {
        (ownerOf[who], inGoodStanding[owner]) = (owner, true);
    }
}

contract RegistryList {
    Registry public immutable REGISTRY;

    constructor(Registry registry) {
        REGISTRY = registry;
    }

    function allows(address, uint256, bytes32 counterparty) external view returns (bytes4) {
        address owner = REGISTRY.ownerOf(counterparty);
        return owner != address(0) && REGISTRY.inGoodStanding(owner) ? ICrestList.allows.selector : bytes4(0);
    }
}

/// Approved merchants in a list contract the principal chooses. Each `test_attack_*` passes when the defence holds.
contract ListTest is CrestBase {
    ScriptedList internal scripted;

    function setUp() public override {
        super.setUp();
        scripted = new ScriptedList();
    }

    function _pointAgentAt(address list) internal {
        ICrestVault.Caps memory c = _caps(HOLD, 3 * HOLD, type(uint128).max, 2, false, true);
        c.list = list;
        _setAgentCaps(c);
    }

    // The default

    /// With no list a grant may pay anyone, bounded still by every list above it.
    function test_noList_paysAnyone_boundedAbove() public {
        _pointAgentAt(address(0));
        H.Terms memory t = _vterms(address(vault), buyer);
        t.sellerPayoutAddress = makeAddr("any payout");
        _fundVia(t, BUYER_PK);
        vm.prank(buyer);
        vault.grant(agentGrant, sub, _wide(), 0, "");
        _pointAgentAt(address(allowList));
        H.Terms memory u = _vterms(address(vault), sub);
        u.sellerPayoutAddress = makeAddr("any payout");
        _expectRefused(u, SUB_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant));
    }

    // The default list

    function test_theDefaultList_isWrittenOnlyByAuthorityAboveTheGrant() public {
        bytes32 m = keccak256("a merchant");
        vm.prank(buyer);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, agentGrant, m, true, "an agent widens its own list");
        vm.prank(stranger);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, agentGrant, m, true, "");
        vm.prank(principal);
        allowList.set(vault, agentGrant, m, true, "the principal approves");
        assertEq(allowList.allows(address(vault), agentGrant, m), ICrestList.allows.selector);
        assertEq(allowList.allows(address(vault), agentGrant, keccak256("another")), bytes4(0));
    }

    /// A contract that claims to be a vault and says yes to everyone writes only its own entries.
    function test_attack_aFakeVaultWritesARealVaultsEntries_refused() public {
        FakeVault fake = new FakeVault();
        bytes32 m = keccak256("a merchant");
        allowList.set(ICrestVault(address(fake)), agentGrant, m, true, "");
        assertTrue(allowList.allowed(address(fake), agentGrant, m));
        assertFalse(allowList.allowed(address(vault), agentGrant, m));
    }

    // Who sets the list

    function test_attack_anAgentChangesItsOwnGrantsList_refused() public {
        ICrestVault.Caps memory c = _caps(HOLD, 3 * HOLD, type(uint128).max, 2, false, true);
        c.list = address(scripted);
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setCaps(agentGrant, c, "an agent points itself at a list that says yes");
        assertEq(_grantOf(vault, agentGrant).caps.list, address(allowList));
    }

    // A list never widens what the parent's list refuses

    function test_attack_aSubAgentsListSaysYes_theAgentsListStillRefuses() public {
        vm.prank(buyer);
        ICrestVault.Caps memory c = _wide();
        c.list = address(scripted);
        uint256 subGrant = vault.grant(agentGrant, sub, c, 0, "");
        H.Terms memory t = _vterms(address(vault), sub);
        t.sellerPayoutAddress = makeAddr("unlisted payout");
        _expectRefused(t, SUB_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant));
        assertEq(_grantOf(vault, subGrant).caps.list, address(scripted));
    }

    function test_attack_aChildVaultsListSaysYes_theParentGrantsListStillRefuses() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vm.prank(buyer);
        vault.fundChild(address(child), 2 * HOLD, "");
        ICrestVault.Caps memory c = _wide();
        c.list = address(scripted);
        vm.prank(buyer);
        child.grant(ROOT, sub, c, 0, "");
        H.Terms memory t = _vterms(address(child), sub);
        t.sellerPayoutAddress = makeAddr("unlisted payout");
        _expectRefused(t, SUB_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant));
    }

    // A list that misbehaves can only refuse

    function test_attack_aListThatMisbehaves_onlyRefuses() public {
        _pointAgentAt(address(scripted));
        ScriptedList.Mode[8] memory bad = [
            ScriptedList.Mode.No,
            ScriptedList.Mode.Revert,
            ScriptedList.Mode.Loop,
            ScriptedList.Mode.TrueNotMagic,
            ScriptedList.Mode.Garbage,
            ScriptedList.Mode.Huge,
            ScriptedList.Mode.Write,
            ScriptedList.Mode.Reenter
        ];
        for (uint256 i; i < bad.length; ++i) {
            scripted.set(bad[i]);
            // A re-entering list can only read: its call back into the vault asks the same list again and runs out of
            // its gas, so it too is a no.
            H.Terms memory t = _vterms(address(vault), buyer);
            _expectRefused(t, BUYER_PK, abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant));
        }
        assertEq(scripted.writes(), 0, "the list wrote nothing");
        assertEq(_grantOf(vault, agentGrant).spent, 0);
        scripted.set(ScriptedList.Mode.Yes);
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
    }

    /// The answer at payment time decides, whatever an earlier simulation saw.
    function test_attack_aListThatChangesItsAnswer_paymentTimeDecides() public {
        _pointAgentAt(address(scripted));
        scripted.set(ScriptedList.Mode.Yes);
        assertEq(scripted.allows(address(vault), agentGrant, _merchant()), ICrestList.allows.selector);
        scripted.set(ScriptedList.Mode.No);
        _expectRefused(
            _vterms(address(vault), buyer),
            BUYER_PK,
            abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant)
        );
    }

    /// A list that refuses everything never locks the principal out: it withdraws and points the grant elsewhere.
    function test_aHostileList_neverLocksThePrincipalOut() public {
        _pointAgentAt(address(scripted));
        scripted.set(ScriptedList.Mode.Loop);
        uint256 all = usdc.balanceOf(address(vault));
        vm.prank(principal);
        vault.withdraw(principal, all / 2, "the principal takes half");
        _pointAgentAt(address(allowList));
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
    }
}

/// Gas, each measured call starting from cold storage: the lists are built in `setUp`, and a test runs in a call of its
/// own. A registry-reading list makes one call to a registry and two reads there, as an identity-based list would.
abstract contract ListGasBase is CrestBase {
    Registry internal registry;
    RegistryList internal byRegistry;

    function setUp() public virtual override {
        super.setUp();
        registry = new Registry();
        registry.register(_merchant(), makeAddr("the merchant's owner"));
        byRegistry = new RegistryList(registry);
    }

    function _funding() internal returns (uint256 used) {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, BUYER_PK);
        uint256 before = gasleft();
        module.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)}));
        used = before - gasleft();
    }
}

contract ListGasTest is ListGasBase {
    function test_gas_theDefaultListsAnswer() public {
        bytes32 m = _merchant();
        uint256 before = gasleft();
        allowList.allows(address(vault), agentGrant, m);
        emit log_named_uint("the default list's answer, cold, gas", before - gasleft());
    }

    function test_gas_aRegistryReadingListsAnswer() public {
        bytes32 m = _merchant();
        uint256 before = gasleft();
        bytes4 yes = byRegistry.allows(address(vault), agentGrant, m);
        uint256 used = before - gasleft();
        assertEq(yes, ICrestList.allows.selector);
        emit log_named_uint("a registry-reading list's answer, cold, gas", used);
        assertLt(used, 30_000, "the cap leaves room for a registry-reading list");
    }

    function test_gas_aFundingThroughTheDefaultList() public {
        emit log_named_uint("a funding through the default list, execution gas", _funding());
    }
}

/// The same funding with the agent's grant pointed at the registry-reading list in `setUp`.
contract ListGasRegistryTest is ListGasBase {
    function setUp() public override {
        super.setUp();
        ICrestVault.Caps memory c = _caps(HOLD, 3 * HOLD, type(uint128).max, 2, false, true);
        c.list = address(byRegistry);
        _setAgentCaps(c);
    }

    function test_gas_aFundingThroughARegistryReadingList() public {
        emit log_named_uint("a funding through a registry-reading list, execution gas", _funding());
    }
}

/// A contract that claims every key is above every grant.
contract FakeVault {
    function isAbove(address, uint256) external pure returns (bool) {
        return true;
    }
}
