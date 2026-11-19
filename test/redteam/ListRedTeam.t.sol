// SPDX-License-Identifier: Apache-2.0
// Crest PR 9 red team (T-554). Goes at test/redteam/ListRedTeam.t.sol; written against d4ca548.
pragma solidity 0.8.28;

import {LibClone} from "solady/utils/LibClone.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestAllowList} from "../../src/CrestAllowList.sol";
import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestFeeSweeper} from "../../src/CrestFeeSweeper.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestAllowList} from "../../src/ICrestAllowList.sol";
import {ICrestList, ICrestVault} from "../../src/ICrestVault.sol";
import {RedTeamBase} from "./RedTeamBase.sol";

bytes4 constant YES = ICrestList.allows.selector;

// Lists for the attacks

/// One answer for every counterparty, and anyone may change it: a list its grant's signer does not control.
contract SwitchList {
    bool public yes;

    function setYes(bool y) external {
        yes = y;
    }

    function allows(address, uint256, bytes32) external view returns (bytes4) {
        return yes ? YES : bytes4(0);
    }
}

contract YesList {
    function allows(address, uint256, bytes32) external pure returns (bytes4) {
        return YES;
    }
}

/// Refuses in one of three hostile ways: 0 reverts, 1 loops until its gas runs out, 2 returns 100,000 bytes.
contract HostileList {
    uint8 public mode;

    function setMode(uint8 m) external {
        mode = m;
    }

    function allows(address, uint256, bytes32) external view returns (bytes4) {
        uint8 m = mode;
        if (m == 0) revert("no");
        if (m == 1) {
            uint256 x;
            while (true) {
                unchecked {
                    ++x;
                }
            }
        }
        bytes4 y = YES;
        assembly {
            mstore(0, y)
            return(0, 100000)
        }
    }
}

/// Says yes only when it has less than `THRESHOLD` gas at its check: the worst list a starved call can meet, because it
/// hands back almost all of its gas. A threshold equal to what it sees with the whole cap makes it say yes whenever it
/// gets even one gas less than the cap, as a best-effort scan that stops early when gas runs low would.
contract StarvedYesList {
    uint256 public immutable THRESHOLD;

    constructor(uint256 threshold) {
        THRESHOLD = threshold;
    }

    function allows(address, uint256, bytes32) external view returns (bytes4) {
        return gasleft() < THRESHOLD ? YES : bytes4(0);
    }
}

/// A registry of eight blocklists; asking it reads eight cold slots, about 17,000 gas, as a shared registry might.
contract Blocklist {
    mapping(uint256 sheet => mapping(bytes32 counterparty => bool)) internal _banned;

    function ban(bytes32 counterparty) external {
        _banned[7][counterparty] = true;
    }

    function banned(bytes32 counterparty) external view returns (bool) {
        for (uint256 i; i < 8; ++i) {
            if (_banned[i][counterparty]) return true;
        }
        return false;
    }
}

/// Allows every counterparty a blocklist does not ban, and fails open when it cannot reach the blocklist.
contract FailOpenList {
    Blocklist public immutable BLOCKLIST;

    constructor(Blocklist b) {
        BLOCKLIST = b;
    }

    function allows(address, uint256, bytes32 counterparty) external view returns (bytes4) {
        try BLOCKLIST.banned(counterparty) returns (bool b) {
            return b ? bytes4(0) : YES;
        } catch {
            return YES;
        }
    }
}

/// Burns a fixed number of rounds, then says yes: a list whose gas need is set when it is deployed.
contract BurnList {
    uint256 public immutable ROUNDS;

    constructor(uint256 rounds) {
        ROUNDS = rounds;
    }

    function allows(address, uint256, bytes32) external view returns (bytes4) {
        uint256 r = ROUNDS;
        uint256 x;
        assembly {
            for { let i := 0 } lt(i, r) { i := add(i, 1) } { x := add(x, i) }
        }
        return x == type(uint256).max ? bytes4(0) : YES;
    }
}

/// Says yes while the agent's grant has no open commitment: true in a simulation, false inside the payment that opens
/// one. It tells a simulation from the payment.
contract TwoFacedList {
    uint256 public immutable LEAF;

    constructor(uint256 leaf) {
        LEAF = leaf;
    }

    function allows(address vault, uint256, bytes32) external view returns (bytes4) {
        return ICrestVault(vault).getGrant(LEAF).open == 0 ? YES : bytes4(0);
    }
}

/// Reads the vault's views and the default list, then tries to write the default list, the vault and itself. Says yes
/// only when every read worked and every write failed.
contract ProbingList {
    CrestAllowList public immutable DEFAULT_LIST;
    address public immutable AGENT;
    uint256 public writes;

    constructor(CrestAllowList d, address agent) {
        (DEFAULT_LIST, AGENT) = (d, agent);
    }

    function bump() external {
        writes++;
    }

    function allows(address vault, uint256 grant, bytes32 counterparty) external returns (bytes4) {
        ICrestVault v = ICrestVault(vault);
        v.isAbove(AGENT, grant);
        v.payeeOf(address(this));
        DEFAULT_LIST.allows(vault, grant, counterparty);
        if (v.isValidSignature(bytes32(0), "") != 0xffffffff) return bytes4(0);
        (bool w1,) = address(this).call{gas: 5000}(abi.encodeCall(this.bump, ()));
        // `collectFee` with nothing owed writes nothing, so it may succeed even here; any fee owed it would move is
        // refused by the static call.
        (bool w2,) = vault.call{gas: 5000}(abi.encodeCall(ICrestVault.collectFee, ()));
        w2;
        (bool w3,) = address(DEFAULT_LIST).call{gas: 5000}(
            abi.encodeCall(ICrestAllowList.set, (v, grant, counterparty, true, ""))
        );
        return !w1 && !w3 ? YES : bytes4(0);
    }
}

/// A list behind a proxy its owner can point at new code.
contract ProxyList {
    address public owner;
    address public impl;

    constructor(address impl_) {
        (owner, impl) = (msg.sender, impl_);
    }

    function upgrade(address impl_) external {
        require(msg.sender == owner, "owner");
        impl = impl_;
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

contract NoList {
    function allows(address, uint256, bytes32) external pure returns (bytes4) {
        return bytes4(0);
    }
}

/// A yes-saying list that can self-destruct.
contract MortalList {
    function allows(address, uint256, bytes32) external pure returns (bytes4) {
        return YES;
    }

    function kill() external {
        selfdestruct(payable(msg.sender));
    }
}

interface IReceiveWithAuthorization {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;
}

/// The cheapest venue module that binds the counterparty to whom it pays: it is its own pinned payee, charges the vault
/// for a merchant, pulls the money and logs the merchant. Little work follows the vault's last list call.
contract CheapVenueModule {
    address public immutable TOKEN;

    event Paid(address indexed merchant, uint256 amount);

    constructor(address token) {
        TOKEN = token;
    }

    function counterpartyOf(address merchant) public pure returns (bytes32) {
        return bytes32(uint256(uint160(merchant)));
    }

    function pay(ICrestVault vault, address controller, uint256 amount, address merchant, bytes32 commitment)
        external
    {
        uint256 validBefore = block.timestamp + 1 hours;
        vault.charge(controller, amount, counterpartyOf(merchant), commitment, validBefore, commitment);
        IReceiveWithAuthorization(TOKEN).receiveWithAuthorization(
            address(vault), address(this), amount, 0, validBefore, commitment, ""
        );
        emit Paid(merchant, amount);
    }
}

/// Claims every key is above every grant.
contract LyingVault {
    function isAbove(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// Shared helpers.
abstract contract ListRedTeamBase is RedTeamBase {
    bytes32 internal constant CAPS_TYPEHASH = keccak256(
        "Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    bytes32 internal constant SIGNED_GRANT_TYPEHASH = keccak256(
        "SignedGrant(uint256 parent,address controller,Caps caps,bytes32 salt,uint40 deadline,bytes note)Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    /// The previous build's types, with `restricted` and the counterparties a slip listed.
    bytes32 internal constant OLD_CAPS_TYPEHASH = keccak256(
        "Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool restricted,bool mayDelegate)"
    );
    bytes32 internal constant OLD_SIGNED_GRANT_TYPEHASH = keccak256(
        "SignedGrant(uint256 parent,address controller,Caps caps,bytes32 salt,bytes32[] counterparties,uint40 deadline,bytes note)Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool restricted,bool mayDelegate)"
    );
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    address internal unlistedPayout;

    function setUp() public virtual override {
        super.setUp();
        unlistedPayout = makeAddr("unlisted payout");
    }

    function _refusedAt(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, id);
    }

    function _unlistedCp() internal view returns (bytes32) {
        return module.counterpartyOf(unlistedPayout, adjudicator, fallbackAdj, appealAdj);
    }

    function _unlisted(address payer, address key) internal returns (H.Terms memory t) {
        t = _vterms(payer, key);
        t.sellerPayoutAddress = unlistedPayout;
    }

    /// Points grant `id` of `v` at `list`, keeping its other limits, as `by`.
    function _setList(CrestVault v, uint256 id, address by, address list) internal {
        ICrestVault.Caps memory c = v.getGrant(id).caps;
        c.list = list;
        vm.prank(by);
        v.setCaps(id, c, "");
    }

    function _domain(address v) internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Crest"), keccak256("1"), block.chainid, v));
    }

    function _structHash(ICrestVault.SignedGrant memory s) internal pure returns (bytes32) {
        return keccak256(
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
    }

    function _sig(uint256 pk, address v, ICrestVault.SignedGrant memory s) internal view returns (bytes memory) {
        (uint8 sv, bytes32 r, bytes32 ss) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", _domain(v), _structHash(s))));
        return abi.encodePacked(r, ss, sv);
    }

    function _slipFor(uint256 parentId, address controller, ICrestVault.Caps memory caps, bytes32 salt)
        internal
        view
        returns (ICrestVault.SignedGrant memory s)
    {
        s = ICrestVault.SignedGrant({
            parent: parentId,
            controller: controller,
            caps: caps,
            salt: salt,
            deadline: uint40(vm.getBlockTimestamp() + 30 days),
            note: "red team"
        });
    }

    function _idOf(ICrestVault.SignedGrant memory s) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(s.parent, s.controller, s.salt)));
    }

    /// Two holds a period, two open, no delegating, and `list`.
    function _twoDeals(address list) internal view returns (ICrestVault.Caps memory c) {
        c = _caps(HOLD, 2 * HOLD, type(uint128).max, 2, false, false);
        c.list = list;
    }

    /// Calls `target` with exactly `g` gas, allocating nothing, and returns the revert's selector.
    function _callGas(address target, bytes memory data, uint256 g) internal returns (bool ok, bytes4 sel) {
        assembly ("memory-safe") {
            ok := call(g, target, 0, add(data, 32), mload(data), 0, 0)
            if gt(returndatasize(), 3) {
                returndatacopy(0, 0, 4)
                sel := and(mload(0), shl(224, 0xffffffff))
            }
        }
    }

    /// Whether `list` answers the yes word to `data` with exactly `g` gas.
    function _staticYes(address list, bytes memory data, uint256 g) internal view returns (bool yes) {
        bytes32 word = bytes32(YES);
        assembly ("memory-safe") {
            let ok := staticcall(g, list, add(data, 32), mload(data), 0, 0)
            if and(ok, eq(returndatasize(), 32)) {
                returndatacopy(0, 0, 32)
                yes := eq(mload(0), word)
            }
        }
    }
}

/// Red team: approved merchants in a list contract the principal chooses (PR 9).
///
/// Every `test_attack_*` passes when the defence holds and fails when the attack works.
contract RedTeamListTest is ListRedTeamBase {
    // 1. A payment to a counterparty some list on the path refuses

    /// Five levels over two vaults, each with no list or a list that says yes or no. A payment lands only when every
    /// list on the path says yes, and a refusal names the first level that refused, walking up.
    function testFuzz_attack_everyListOnThePathMustSayYes(uint8 present, uint8 answers) public {
        (CrestVault child, uint256 subInChild) = _agentChild(2 * HOLD);
        vm.prank(sub);
        uint256 sub2Grant = child.grant(subInChild, sub2, _wide(), 0, "");
        // Walk order: the leaf in the child, its parent, the child's root, then the agent's grant and the root above.
        CrestVault[5] memory vs = [child, child, child, vault, vault];
        uint256[5] memory ids = [sub2Grant, subInChild, ROOT, agentGrant, ROOT];
        address[5] memory by = [sub, buyer, principal, principal, principal];
        bool lands = true;
        uint256 firstNo;
        for (uint256 i; i < 5; ++i) {
            address list;
            if ((present >> i) & 1 == 1) {
                SwitchList l = new SwitchList();
                bool y = (answers >> i) & 1 == 1;
                l.setYes(y);
                list = address(l);
                if (!y && lands) (lands, firstNo) = (false, ids[i]);
            }
            _setList(vs[i], ids[i], by[i], list);
        }
        H.Terms memory t = _vterms(address(child), sub2);
        if (lands) _fundVia(t, SUB2_PK);
        else _expectRefused(t, SUB2_PK, _refusedAt(firstNo));
    }

    /// A grandchild vault two levels down pays only what every vault above allows: the top vault's list for the agent,
    /// and the middle vault's list for the sub-agent, while the grandchild's own list says yes to everyone.
    function test_attack_aGrandchildPaysPastAListTwoVaultsUp_refused() public {
        (CrestVault child, uint256 subInChild) = _agentChild(3 * HOLD);
        vm.prank(sub);
        CrestVault grand = CrestVault(child.createChild(subInChild, 0, ""));
        vm.prank(sub);
        child.fundChild(address(grand), 2 * HOLD, "");
        YesList yes = new YesList();
        ICrestVault.Caps memory c = _wide();
        c.list = address(yes);
        vm.prank(sub);
        grand.grant(ROOT, sub2, c, 0, "");

        _expectRefused(_unlisted(address(grand), sub2), SUB2_PK, _refusedAt(agentGrant));
        SwitchList middle = new SwitchList();
        _setList(child, subInChild, buyer, address(middle));
        _expectRefused(_vterms(address(grand), sub2), SUB2_PK, _refusedAt(subInChild));
        middle.setYes(true);
        _fundVia(_vterms(address(grand), sub2), SUB2_PK);
    }

    /// Precompiles, an address with no code, and contracts with no `allows` (the vault, the token, the module, the
    /// factory, the rules contract) are each a no.
    function test_attack_aPrecompileOrACodelessOrUnrelatedAddressAsTheList_neverPays() public {
        address[23] memory odd;
        for (uint160 i = 1; i <= 0x11; ++i) {
            odd[i - 1] = address(i);
        }
        odd[17] = address(0x100);
        odd[18] = makeAddr("no code at all");
        odd[19] = address(vault);
        odd[20] = address(usdc);
        odd[21] = address(module);
        odd[22] = address(factory);
        bytes32 m = _merchant();
        for (uint256 i; i < odd.length; ++i) {
            _setList(vault, agentGrant, principal, odd[i]);
            vm.expectRevert(_refusedAt(agentGrant));
            vault.checkPath(agentGrant, HOLD, m);
        }
        _setList(vault, agentGrant, principal, address(rules));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _refusedAt(agentGrant));
        _setList(vault, agentGrant, principal, address(0x04)); // the identity precompile echoes its input
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _refusedAt(agentGrant));
    }

    /// A list that says yes to a simulation (`checkPath`) and no inside the payment: the payment's answer decides.
    function test_attack_aListThatTellsASimulationFromThePayment_paymentTimeDecides() public {
        TwoFacedList two = new TwoFacedList(agentGrant);
        _setList(vault, ROOT, principal, address(two));
        vault.checkPath(agentGrant, HOLD, _merchant());
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _refusedAt(ROOT));
        assertEq(_grantOf(vault, agentGrant).spent, 0);
    }

    /// A list that reads the vault and the default list and tries to write the default list, the vault and itself:
    /// every write fails under the vault's read-only call, so it can only answer.
    function test_attack_aListThatCallsBackIntoTheVaultAndTheDefaultList_onlyReads() public {
        ProbingList probe = new ProbingList(allowList, buyer);
        _setList(vault, ROOT, principal, address(probe));
        bytes32 m = _merchant();
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        assertEq(probe.writes(), 0, "the list wrote its own storage");
        assertTrue(allowList.allowed(address(vault), agentGrant, m));
        assertFalse(allowList.allowed(address(vault), ROOT, m), "the list wrote the default list");
        _expectRefused(_unlisted(address(vault), buyer), BUYER_PK, _refusedAt(agentGrant));
    }

    /// A return-data bomb above a child vault only refuses its payment; the principal still takes the money back.
    function test_attack_aReturnDataBombAboveAChild_onlyRefuses() public {
        (CrestVault child,) = _agentChild(2 * HOLD);
        HostileList bomb = new HostileList();
        bomb.setMode(2);
        _setList(vault, agentGrant, principal, address(bomb));
        H.Terms memory t = _vterms(address(child), sub);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, SUB_PK);
        uint256 before = gasleft();
        try module.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)})) {
            fail();
        } catch (bytes memory err) {
            assertEq(err, _refusedAt(agentGrant));
        }
        emit log_named_uint("a payment refused by a 100,000-byte answer, gas", before - gasleft());
        vm.prank(principal);
        vault.takeBackFromChild(address(child), 2 * HOLD, "");
        assertEq(usdc.balanceOf(address(child)), 0);
    }

    // 2. Signed grants name a list, not entries

    /// A slip's list changed after signing: the vault recovers another signer, which has no authority.
    function testFuzz_attack_aSlipLandsExactlyTheListItsSignerSigned(address signedList, address submittedList)
        public
    {
        vm.assume(signedList != submittedList);
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _twoDeals(signedList), "exact");
        bytes memory sig = _sig(BUYER_PK, address(vault), s);
        uint256 snap = vm.snapshotState();
        vm.prank(buyer);
        uint256 byTx = vault.grant(agentGrant, sub, _twoDeals(signedList), "exact", "");
        vm.revertToState(snap);

        ICrestVault.SignedGrant memory tampered = _slipFor(agentGrant, sub, _twoDeals(submittedList), "exact");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(tampered, sig);
        uint256 id = vault.grantBySig(s, sig);
        assertEq(id, byTx, "the slip lands where the signer's grant would");
        assertEq(_grantOf(vault, id).caps.list, signedList);
    }

    /// A slip signed under the previous build's type (with `restricted` and listed counterparties) lands nothing under
    /// the new type, with or without a list.
    function test_attack_aSlipSignedUnderThePreviousTypeLandsNothing() public {
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _twoDeals(address(0)), "old type");
        bytes32[] memory cps = new bytes32[](1);
        cps[0] = _unlistedCp();
        ICrestVault.Caps memory c = s.caps;
        bytes32 oldCaps = keccak256(
            abi.encode(
                OLD_CAPS_TYPEHASH, c.perSpend, c.perPeriod, c.lifetime, c.maxOpen, c.period, c.expiresAt, true, false
            )
        );
        bytes32 oldStruct = keccak256(
            abi.encode(
                OLD_SIGNED_GRANT_TYPEHASH,
                s.parent,
                s.controller,
                oldCaps,
                s.salt,
                keccak256(abi.encodePacked(cps)),
                s.deadline,
                keccak256(s.note)
            )
        );
        (uint8 v, bytes32 r, bytes32 ss) =
            vm.sign(BUYER_PK, keccak256(abi.encodePacked("\x19\x01", _domain(address(vault)), oldStruct)));
        bytes memory sig = abi.encodePacked(r, ss, v);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(s, sig);
        s.caps.list = address(allowList);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.grantBySig(s, sig);
        assertEq(vault.grantOf(sub), 0);
    }

    /// A slip names a list a stranger controls. The stranger widens it after signing: the slip's key pays only what the
    /// signer's own grant allows at payment time, and a narrowing above, after the slip landed, binds it at once.
    function test_attack_aSlipsListWidenedAfterSigning_staysInsideTheSignersPath() public {
        SwitchList shared = new SwitchList();
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _twoDeals(address(shared)), "widened later");
        uint256 id = vault.grantBySig(s, _sig(BUYER_PK, address(vault), s));
        _expectRefused(_vterms(address(vault), sub), SUB_PK, _refusedAt(id));

        vm.prank(stranger);
        shared.setYes(true);
        _expectRefused(_unlisted(address(vault), sub), SUB_PK, _refusedAt(agentGrant));
        _expectRefused(_unlisted(address(vault), buyer), BUYER_PK, _refusedAt(agentGrant));
        _fundVia(_vterms(address(vault), sub), SUB_PK);

        bytes32 m = _merchant();
        vm.prank(principal);
        allowList.set(vault, agentGrant, m, false, "the principal narrows the agent");
        _expectRefused(_vterms(address(vault), sub), SUB_PK, _refusedAt(agentGrant));
    }

    /// For every state of the signer's list and the slip's list, and either payee, the slip's key lands a payment only
    /// when its signer could land the same payment by transaction at that moment.
    function testFuzz_attack_aSlipPaysOnlyWhatItsSignerCouldPayNow(bool agentAllows, bool slipSaysYes, bool listed)
        public
    {
        SwitchList slipList = new SwitchList();
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _twoDeals(address(slipList)), "compare");
        vault.grantBySig(s, _sig(BUYER_PK, address(vault), s));
        slipList.setYes(slipSaysYes);
        bytes32 m = _merchant();
        vm.prank(principal);
        allowList.set(vault, agentGrant, m, agentAllows, "");

        uint256 snap = vm.snapshotState();
        bool subLanded = _tryFundVia(listed ? _vterms(address(vault), sub) : _unlisted(address(vault), sub), SUB_PK);
        vm.revertToState(snap);
        bool signerLanded =
            _tryFundVia(listed ? _vterms(address(vault), buyer) : _unlisted(address(vault), buyer), BUYER_PK);
        if (subLanded) assertTrue(signerLanded, "the slip paid what its signer could not");
        assertEq(subLanded, slipSaysYes && signerLanded);
    }

    /// A slip that names the default list: its signer cannot list counterparties for it before it lands (its grant
    /// does not exist yet, so the signer is not above it), while the principal can. After landing it pays no one until
    /// someone above lists a counterparty by transaction, and an unlisting binds at once.
    function test_aSlipNamingTheDefaultList_paysNoOneUntilListedByTransaction() public {
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _twoDeals(address(allowList)), "default list");
        uint256 id = _idOf(s);
        bytes32 m = _merchant();
        vm.prank(buyer);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, id, m, true, "the signer lists before landing");
        assertTrue(vault.isAbove(principal, id), "the principal is above an ID that does not exist yet");

        vault.grantBySig(s, _sig(BUYER_PK, address(vault), s));
        _expectRefused(_vterms(address(vault), sub), SUB_PK, _refusedAt(id));
        vm.prank(sub);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, id, m, true, "the slip's key lists itself");

        vm.prank(buyer);
        allowList.set(vault, id, m, true, "the signer lists after landing");
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        vm.prank(buyer);
        allowList.set(vault, id, m, false, "the signer narrows");
        _expectRefused(_vterms(address(vault), sub), SUB_PK, _refusedAt(id));
    }

    /// A slip names a list the slip's own key controls, which says yes to everyone: the key pays only what the
    /// signer's path allows.
    function test_attack_aSlipNamingTheSubAgentsOwnList_boundedByTheSignersPath() public {
        vm.prank(sub);
        YesList own = new YesList();
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _twoDeals(address(own)), "the key's own list");
        vault.grantBySig(s, _sig(BUYER_PK, address(vault), s));
        _expectRefused(_unlisted(address(vault), sub), SUB_PK, _refusedAt(agentGrant));
        _fundVia(_vterms(address(vault), sub), SUB_PK);
    }

    /// A slip names a list behind a proxy; after the slip lands, the proxy's owner points it at code that says yes.
    function test_attack_aSlipsListUpgradedToSayYes_boundedByTheSignersPath() public {
        NoList no = new NoList();
        YesList yes = new YesList();
        vm.prank(stranger);
        ProxyList proxy = new ProxyList(address(no));
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _twoDeals(address(proxy)), "behind a proxy");
        uint256 id = vault.grantBySig(s, _sig(BUYER_PK, address(vault), s));
        _expectRefused(_vterms(address(vault), sub), SUB_PK, _refusedAt(id));
        vm.prank(stranger);
        proxy.upgrade(address(yes));
        _expectRefused(_unlisted(address(vault), sub), SUB_PK, _refusedAt(agentGrant));
        _fundVia(_vterms(address(vault), sub), SUB_PK);
    }

    /// A slip's list that self-destructs keeps its code (EIP-6780), and a list whose code is gone, or replaced in
    /// place, is asked as it is at payment: no code is a no, and new code is bounded by the signer's path.
    function test_attack_aSlipsListDestroyedOrReplacedInPlace_boundedByThePath() public {
        MortalList mortal = new MortalList();
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _twoDeals(address(mortal)), "mortal");
        uint256 id = vault.grantBySig(s, _sig(BUYER_PK, address(vault), s));
        mortal.kill();
        _expectRefused(_unlisted(address(vault), sub), SUB_PK, _refusedAt(agentGrant));
        vm.etch(address(mortal), "");
        _expectRefused(_vterms(address(vault), sub), SUB_PK, _refusedAt(id));
        vm.etch(address(mortal), address(new YesList()).code);
        _expectRefused(_unlisted(address(vault), sub), SUB_PK, _refusedAt(agentGrant));
        _fundVia(_vterms(address(vault), sub), SUB_PK);
    }

    /// A slip names an address with no code that a key holds. The key gives it code by EIP-7702: the list now says
    /// yes, still bounded by the signer's path.
    function test_attack_aCodelessListGainsCodeByEip7702_boundedByThePath() public {
        YesList yes = new YesList();
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub2, _twoDeals(sub), "an address with no code");
        uint256 id = vault.grantBySig(s, _sig(BUYER_PK, address(vault), s));
        _expectRefused(_vterms(address(vault), sub2), SUB2_PK, _refusedAt(id));
        bytes memory ask = abi.encodeCall(ICrestList.allows, (address(vault), id, _merchant()));
        vm.signAndAttachDelegation(address(yes), SUB_PK);
        (bool ok,) = sub.call(ask);
        assertTrue(ok);
        assertGt(sub.code.length, 0, "the key's address has code");
        _expectRefused(_unlisted(address(vault), sub2), SUB2_PK, _refusedAt(agentGrant));
        _fundVia(_vterms(address(vault), sub2), SUB2_PK);
    }

    // 3. A list never locks the principal out, and never touches a funded deal

    /// Two deals funded, then every list on the path turns hostile (revert, loop, return-data bomb). Both deals settle
    /// by their terms, both commitments end, and the principal pauses, resumes, withdraws and points the lists away.
    function test_attack_hostileListsAfterFunding_blockNoSettlementStopOrWithdrawal() public {
        H.Terms memory t1 = _vterms(address(vault), buyer);
        bytes32 id1 = _fundVia(t1, BUYER_PK);
        H.Terms memory t2 = _vterms(address(vault), buyer);
        bytes32 id2 = _fundVia(t2, BUYER_PK);
        HostileList bad = new HostileList();
        _setList(vault, ROOT, principal, address(bad));
        _setList(vault, agentGrant, principal, address(bad));
        bytes32 merchant = _merchant();
        for (uint8 m; m < 3; ++m) {
            bad.setMode(m);
            vm.expectRevert(_refusedAt(agentGrant));
            vault.checkPath(agentGrant, HOLD, merchant);
            vm.startPrank(principal);
            vault.setPaused(agentGrant, true, "");
            vault.setPaused(agentGrant, false, "");
            vault.withdraw(principal, HOLD, "");
            vm.stopPrank();
        }
        bad.setMode(1);
        _release(t1, id1);
        _deliver(t2, id2);
        rules.decide(t2, _primary(t2, id2, H.OUTCOME_REJECT), _noDelivery(), "");
        assertEq(uint8(_stage(id2)), uint8(IHoldbackRules.Stage.Refunded));
        module.close(t1);
        module.close(t2);
        assertEq(_grantOf(vault, agentGrant).open, 0);

        _setList(vault, ROOT, principal, address(0));
        _setList(vault, agentGrant, principal, address(allowList));
        vm.prank(principal);
        vault.close(agentGrant, "");
        assertTrue(_grantOf(vault, agentGrant).closed);
    }

    /// A list on the root that refuses everything: no one pays, the agent cannot repoint it, the principal can.
    function test_attack_aHostileListOnTheRoot_onlyThePrincipalRepointsIt() public {
        HostileList bad = new HostileList();
        bad.setMode(1);
        _setList(vault, ROOT, principal, address(bad));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _refusedAt(ROOT));
        ICrestVault.Caps memory c = _grantOf(vault, ROOT).caps;
        c.list = address(0);
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setCaps(ROOT, c, "");
        vm.prank(principal);
        vault.setCaps(ROOT, c, "");
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
    }

    /// The agent points every grant in its child vault at a looping list and cannot repoint the child's root. The
    /// principal still takes the child's money back, and the agent can still send it up.
    function test_attack_aHostileListInsideAChildVault_blocksNoTakeBack() public {
        (CrestVault child, uint256 subInChild) = _agentChild(2 * HOLD);
        HostileList bad = new HostileList();
        bad.setMode(1);
        _setList(child, subInChild, buyer, address(bad));
        ICrestVault.Caps memory c = _grantOf(child, ROOT).caps;
        c.list = address(bad);
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        child.setCaps(ROOT, c, "");
        vm.prank(principal);
        child.setCaps(ROOT, c, "");
        _expectRefused(_vterms(address(child), sub), SUB_PK, _refusedAt(subInChild));
        vm.prank(buyer);
        child.returnToParent(HOLD, "");
        vm.prank(principal);
        vault.takeBackFromChild(address(child), HOLD, "");
        assertEq(usdc.balanceOf(address(child)), 0);
    }

    // 4. Who writes a grant's entries in the default list, and who changes a grant's list

    /// Nobody at or below a grant, beside it or outside the tree writes its entries; only authority above it does.
    function test_attack_noOneAtBelowOrBesideAGrantWritesItsEntries() public {
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _wide(), 0, "");
        vm.prank(buyer);
        uint256 sibling = vault.grant(agentGrant, sub2, _wide(), 0, "");
        address pending = makeAddr("pending principal");
        vm.prank(principal);
        vault.proposePrincipal(pending, "");
        bytes32 u = _unlistedCp();

        address[10] memory who = [buyer, buyer, sub, sub, sub, sub2, stranger, address(module), pending, sub];
        uint256[10] memory ids =
            [agentGrant, ROOT, subGrant, agentGrant, sibling, subGrant, agentGrant, agentGrant, ROOT, ROOT];
        for (uint256 i; i < who.length; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
            allowList.set(vault, ids[i], u, true, "");
        }
        vm.prank(buyer);
        allowList.set(vault, subGrant, u, true, "the agent lists for its sub-agent");
        vm.prank(principal);
        allowList.set(vault, ROOT, u, true, "the principal lists for the root");
        assertFalse(allowList.allowed(address(vault), agentGrant, u));
    }

    /// The coordinator's first question. A sub-agent and its controller each try to widen the list a parent's grant or
    /// a slip points to: by the default list, by repointing, and by re-granting their own key.
    function test_attack_aSubAgentOrItsControllerWidensAParentsOrASlipsList_refused() public {
        ICrestVault.Caps memory c = _caps(HOLD, 2 * HOLD, type(uint128).max, 2, true, true);
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, c, "a slip on the default list");
        uint256 slipId = vault.grantBySig(s, _sig(BUYER_PK, address(vault), s));
        bytes32 u = _unlistedCp();
        bytes32 m = _merchant();
        ICrestVault.Caps memory open = c;
        open.list = address(0);

        vm.startPrank(sub);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, slipId, u, true, "");
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, agentGrant, u, true, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setCaps(slipId, open, "");
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.grant(slipId, sub, _wide(), "move under itself", "");
        vm.stopPrank();

        vm.startPrank(buyer);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, agentGrant, u, true, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setCaps(agentGrant, open, "");
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.grant(agentGrant, buyer, _wide(), "move under itself", "");
        allowList.set(vault, slipId, u, true, "the signer widens the slip");
        allowList.set(vault, slipId, m, true, "");
        vm.stopPrank();

        _expectRefused(_unlisted(address(vault), sub), SUB_PK, _refusedAt(agentGrant));
        _fundVia(_vterms(address(vault), sub), SUB_PK);
    }

    /// Once the principal closes the agent, the agent writes no entry for its sub-agent here. In its child vault it
    /// still manages grants, as the interface says, but none of them can pay.
    function test_attack_aClosedAgentsEntries_refusedHere_inertInItsChild() public {
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub2, _caps(HOLD, HOLD, HOLD, 1, true, false), 0, "");
        (CrestVault child, uint256 subInChild) = _agentChild(2 * HOLD);
        _setList(child, subInChild, buyer, address(allowList));
        vm.prank(principal);
        vault.close(agentGrant, "");
        bytes32 u = _unlistedCp();
        bytes32 m = _merchant();

        vm.prank(buyer);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, subGrant, u, true, "");
        vm.startPrank(buyer);
        allowList.set(child, subInChild, u, true, "");
        allowList.set(child, subInChild, m, true, "");
        vm.stopPrank();
        bytes memory closed = abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant);
        _expectRefused(_unlisted(address(child), sub), SUB_PK, closed);
        _expectRefused(_vterms(address(child), sub), SUB_PK, closed);
        vm.prank(principal);
        vault.takeBackFromChild(address(child), 2 * HOLD, "");
    }

    /// A paused agent is still above its sub-agent and may list for it (a pause has no rank), but the pause stops
    /// every payment below.
    function test_attack_aPausedAgentListsForItsSubAgent_paymentStillStopped() public {
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _twoDeals(address(allowList)), 0, "");
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "");
        bytes32 u = _unlistedCp();
        vm.prank(buyer);
        allowList.set(vault, subGrant, u, true, "");
        _expectRefused(
            _unlisted(address(vault), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant)
        );
    }

    /// Across a handover: the proposed principal writes nothing before it accepts, the previous one nothing after, in
    /// the vault and in its child vaults. The previous principal's entries stay and still answer.
    function test_attack_acrossAHandover_onlyTheCurrentPrincipalWritesEntries() public {
        (CrestVault child, uint256 subInChild) = _agentChild(HOLD);
        address next = makeAddr("next principal");
        vm.prank(principal);
        vault.proposePrincipal(next, "");
        bytes32 u = _unlistedCp();
        bytes32 m = _merchant();
        vm.prank(next);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, agentGrant, u, true, "");
        vm.prank(next);
        vault.acceptPrincipal("");

        vm.startPrank(principal);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, agentGrant, m, false, "");
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(child, subInChild, u, true, "");
        vm.stopPrank();
        assertTrue(allowList.allowed(address(vault), agentGrant, m), "the previous principal's entry stays");
        vm.prank(next);
        allowList.set(vault, agentGrant, m, false, "the new principal reviews it");
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _refusedAt(agentGrant));
    }

    /// Entries written for a contract that claims to be a vault, for a vault of another factory with the same grant
    /// IDs, for a clone of the real code that names this vault as its parent, and for a child vault whose root has the
    /// same ID as its parent's: none answers for this vault.
    function test_attack_entriesOfAnotherVaultNeverAnswerForThisOne() public {
        bytes32 u = _unlistedCp();
        LyingVault liar = new LyingVault();
        vm.prank(stranger);
        allowList.set(ICrestVault(address(liar)), agentGrant, u, true, "");

        CrestFactory other = new CrestFactory(0, address(0));
        CrestVault v2 = CrestVault(other.create(stranger, address(usdc), 0));
        vm.prank(stranger);
        uint256 sameId = v2.grant(ROOT, buyer, _wide(), 0, "");
        assertEq(sameId, agentGrant);
        vm.prank(stranger);
        allowList.set(v2, sameId, u, true, "");

        CrestVault rogue = CrestVault(LibClone.clone(factory.IMPLEMENTATION()));
        vm.prank(stranger);
        rogue.initialize(stranger, address(usdc), address(vault), agentGrant);
        vm.prank(stranger);
        uint256 rogueId = rogue.grant(ROOT, buyer, _wide(), 0, "");
        assertEq(rogueId, agentGrant);
        vm.prank(stranger);
        allowList.set(rogue, rogueId, u, true, "");
        vm.prank(stranger);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(vault, agentGrant, u, true, "");

        (CrestVault child,) = _agentChild(HOLD);
        vm.prank(buyer);
        vm.expectRevert(ICrestAllowList.NotAuthorized.selector);
        allowList.set(child, ROOT, u, true, "the child's own principal writes its root's entries");
        vm.prank(principal);
        allowList.set(child, ROOT, u, true, "");
        _setList(child, ROOT, principal, address(allowList));

        assertFalse(allowList.allowed(address(vault), agentGrant, u));
        _expectRefused(_unlisted(address(vault), buyer), BUYER_PK, _refusedAt(agentGrant));
        _expectRefused(_unlisted(address(child), sub), SUB_PK, _refusedAt(agentGrant));
        _expectRefused(_vterms(address(child), sub), SUB_PK, _refusedAt(ROOT));
    }

    /// The agent cancels a slip and so is above the closed record it leaves; the entries it writes there answer for
    /// nothing, because that ID can never land.
    function test_attack_entriesForACancelledSlip_answerForNothing() public {
        vm.prank(buyer);
        vault.cancelSignedGrant(agentGrant, sub, "cancelled", "");
        ICrestVault.SignedGrant memory s = _slipFor(agentGrant, sub, _twoDeals(address(allowList)), "cancelled");
        uint256 id = _idOf(s);
        bytes32 u = _unlistedCp();
        vm.prank(buyer);
        allowList.set(vault, id, u, true, "");
        bytes memory sig = _sig(BUYER_PK, address(vault), s);
        vm.expectRevert(ICrestVault.GrantExists.selector);
        vault.grantBySig(s, sig);
        assertEq(vault.grantOf(sub), 0);
    }

    // 5. The fee and the list together

    /// With a fee, a list's refusal owes and counts nothing; a hostile list on every level blocks neither the fee's
    /// collection nor a withdrawal.
    function test_attack_aListRefusalWithAFee_owesNothing_andBlocksNoCollection() public {
        address dest = makeAddr("fee destination");
        CrestFeeSweeper sweeper = new CrestFeeSweeper(dest);
        CrestFactory ff = new CrestFactory(100, address(sweeper));
        CrestVault fv = CrestVault(ff.create(principal, address(usdc), bytes32("a vault with a fee")));
        bytes32 m = _merchant();
        vm.startPrank(principal);
        fv.setModule(address(module), module.payee(), "");
        uint256 fg = fv.grant(ROOT, buyer, _caps(2 * HOLD, 4 * HOLD, type(uint128).max, 5, true, true), 0, "");
        allowList.set(fv, fg, m, true, "");
        vm.stopPrank();
        usdc.mint(address(fv), 10 * HOLD);

        _expectRefused(_unlisted(address(fv), buyer), BUYER_PK, _refusedAt(fg));
        assertEq(fv.feeOwed(), 0);
        assertEq(_grantOf(fv, fg).spent, 0);
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        uint256 owed = fv.feeOwed();
        assertEq(owed, HOLD * 100 / 10_000);

        HostileList bad = new HostileList();
        bad.setMode(1);
        _setList(fv, ROOT, principal, address(bad));
        _setList(fv, fg, principal, address(bad));
        sweeper.sweep(fv);
        assertEq(usdc.balanceOf(dest), owed);
        uint256 rest = usdc.balanceOf(address(fv));
        vm.prank(principal);
        fv.withdraw(principal, rest, "");
        assertEq(usdc.balanceOf(address(fv)), 0);
    }
}

/// The gas cap (`LIST_GAS`, 30,000). Every probe of the default list reads a slot no earlier probe read.
contract RedTeamListGasTest is ListRedTeamBase {
    uint256 internal constant PROBES = 24;
    uint256 internal constant CAP = 30_000;

    function setUp() public override {
        super.setUp();
        vm.startPrank(principal);
        for (uint256 i; i < PROBES; ++i) {
            allowList.set(vault, agentGrant, _probe(i), true, "");
        }
        vm.stopPrank();
    }

    function _probe(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("probe", i));
    }

    function _ask(uint256 i) internal view returns (bytes memory) {
        return abi.encodeCall(ICrestList.allows, (address(vault), agentGrant, _probe(i)));
    }

    /// The least gas with which `list` answers yes to `data`, for a list that keeps no state.
    function _needOf(address list, bytes memory data) internal view returns (uint256 hi) {
        uint256 lo;
        hi = 200_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_staticYes(list, data, mid)) hi = mid;
            else lo = mid;
        }
    }

    /// The coordinator's fourth question, first half: the default list's answer from cold storage fits the cap.
    function test_gas_theDefaultListsColdAnswer_fitsTheCap() public {
        address list = address(allowList);
        bytes memory first = _ask(0);
        uint256 g0 = gasleft();
        assertTrue(_staticYes(list, first, CAP));
        uint256 cold = g0 - gasleft();
        g0 = gasleft();
        assertTrue(_staticYes(list, first, CAP));
        uint256 warm = g0 - gasleft();
        assertGe(cold - warm, 2000, "the first probe read cold storage");

        uint256 lo;
        uint256 hi = CAP;
        uint256 k = 1;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_staticYes(list, _ask(k++), mid)) hi = mid;
            else lo = mid;
        }
        assertLt(k + 2, PROBES, "every probe was cold");
        assertTrue(_staticYes(list, _ask(k++), hi), "a cold answer with the least gas");
        assertFalse(_staticYes(list, _ask(k++), hi - 1), "and one gas less is a no");
        emit log_named_uint("the default list's cold answer needs, gas", hi);
        emit log_named_uint("cold minus warm, gas", cold - warm);
        assertLt(hi, CAP);
    }

    /// The coordinator's fourth question, second half: a list that needs exactly the cap or less pays; one round more
    /// is refused, and the vault never pays on a list it starved.
    function test_attack_aListThatNeedsTheCapPays_aLittleMoreIsRefused() public {
        bytes memory data = _ask(0);
        uint256 lo;
        uint256 hi = 5000;
        assertFalse(_staticYes(address(new BurnList(hi)), data, CAP));
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_staticYes(address(new BurnList(mid)), data, CAP)) lo = mid;
            else hi = mid;
        }
        BurnList fits = new BurnList(lo);
        BurnList over = new BurnList(lo + 1);
        uint256 needFits = _needOf(address(fits), data);
        uint256 needOver = _needOf(address(over), data);
        emit log_named_uint("rounds that fit the cap", lo);
        emit log_named_uint("gas the fitting list needs", needFits);
        emit log_named_uint("gas the list one round over needs", needOver);
        assertLe(needFits, CAP);
        assertGt(needOver, CAP);

        _setList(vault, agentGrant, principal, address(over));
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _refusedAt(agentGrant));
        _setList(vault, agentGrant, principal, address(fits));
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
    }
}

/// Starving a list: the payment sent with too little gas for the list to get its cap.
///
/// A list call gets min(30,000, 63/64 of what is left). Below that the list is starved, and a list that fails open
/// would say yes. The vault is safe only if what follows the list call can never finish on what is left.
abstract contract StarvationBase is ListRedTeamBase {
    uint256 internal constant WINDOW = 32_000;
    /// The gas a scan may spend, under the test's own limit of 1,073,741,824.
    uint256 internal constant SCAN_BUDGET = 700_000_000;

    /// The least gas from which `data` is refused by name, `err`, at every value up to ample gas: from there up the
    /// list has the gas to say no. Searched downwards, because a list starved below its own need refuses by name too.
    function _leastRefusedByName(address target, bytes memory data, bytes4 err) internal returns (uint256 g) {
        g = 400_000;
        (bool ok, bytes4 sel) = _callGas(target, data, g);
        assertFalse(ok, "landed with ample gas");
        assertEq(sel, err, "refused by name with ample gas");
        for (uint256 stride = 512; stride != 0; stride /= 8) {
            while (true) {
                (ok, sel) = _callGas(target, data, g - stride);
                if (ok) {
                    emit log_named_uint("landed with gas", g - stride);
                    fail();
                    return g;
                }
                if (sel != err) break;
                g -= stride;
            }
        }
    }

    /// Sends `data` at evenly spaced gas values from `WINDOW` below the least named refusal up to it, as many as the
    /// budget allows, and fails on any landing.
    function _scan(address target, bytes memory data, bytes4 err) internal returns (uint256 top) {
        top = _leastRefusedByName(target, data, err);
        uint256 step = WINDOW * top / SCAN_BUDGET + 1;
        emit log_named_uint("scan step, gas", step);
        uint256 tried;
        for (uint256 g = top > WINDOW ? top - WINDOW : 0; g <= top; g += step) {
            (bool ok,) = _callGas(target, data, g);
            if (ok) {
                emit log_named_uint("landed with gas", g);
                fail();
                return top;
            }
            ++tried;
        }
        emit log_named_uint("least gas refused by name", top);
        emit log_named_uint("gas values tried below it", tried);
    }

    function _starveRoot() internal {
        _setList(vault, ROOT, principal, address(new StarvedYesList(29_000)));
    }

    /// Points the root at a list that says no with the whole cap and yes with any less: its threshold is the most gas
    /// it can see at its check, found by asking it directly with exactly the cap.
    function _starveRootExactly() internal returns (StarvedYesList list) {
        bytes memory ask = abi.encodeCall(ICrestList.allows, (address(vault), ROOT, bytes32(0)));
        uint256 lo = 28_000;
        uint256 hi = 30_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_staticYes(address(new StarvedYesList(mid)), ask, 30_000)) hi = mid;
            else lo = mid;
        }
        list = new StarvedYesList(lo);
        assertFalse(_staticYes(address(list), ask, 30_000), "no with the whole cap");
        assertTrue(_staticYes(address(list), ask, 29_999), "yes with one gas less");
        _setList(vault, ROOT, principal, address(list));
    }

    /// The least gas with which `data` lands when the root's list says yes, each probe undone.
    function _leastLanding(address target, bytes memory data) internal returns (uint256 hi) {
        _setList(vault, ROOT, principal, address(new YesList()));
        uint256 lo;
        hi = 2_000_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = _callGas(target, data, mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    function _blocklisted() internal returns (bytes memory data) {
        Blocklist bl = new Blocklist();
        bl.ban(_unlistedCp());
        _setList(vault, agentGrant, principal, address(new FailOpenList(bl)));
        data = _fundCall(_unlisted(address(vault), buyer), BUYER_PK);
    }
}

contract RedTeamListStarvationTest is StarvationBase {
    /// The root's list is the last one a top vault's payment asks.
    function test_attack_starvingTheLastListOfAPayment_neverLands() public {
        _starveRoot();
        _scan(
            address(module),
            _fundCall(_vterms(address(vault), buyer), BUYER_PK),
            ICrestVault.CounterpartyNotAllowed.selector
        );
    }

    /// The top vault's root list is the last one a child vault's payment asks, inside the parent's `checkPath`.
    function test_attack_starvingTheParentVaultsListOfAChildPayment_neverLands() public {
        (CrestVault child,) = _agentChild(2 * HOLD);
        _starveRoot();
        _scan(
            address(module),
            _fundCall(_vterms(address(child), sub), SUB_PK),
            ICrestVault.CounterpartyNotAllowed.selector
        );
    }

    /// The thinnest margin: a child vault pays through the cheapest venue module, the only list is the top vault's
    /// root, which says yes when starved, and the payee's balance and the token are already warm. What follows the list
    /// call is the child's tail, one ERC-3009 pull with a fresh nonce, and a log.
    function test_attack_starvingTheParentsListThroughACheapVenueModule_neverLands() public {
        CheapVenueModule venue = new CheapVenueModule(address(usdc));
        vm.prank(principal);
        vault.setModule(address(venue), address(venue), "");
        usdc.mint(address(venue), 1);
        (CrestVault child,) = _agentChild(2 * HOLD);
        _setList(vault, agentGrant, principal, address(0));
        _starveRoot();
        address merchant = makeAddr("a merchant the root refuses");
        bytes memory data = abi.encodeCall(CheapVenueModule.pay, (child, sub, HOLD, merchant, keccak256("one")));
        (bool ok,) = _callGas(
            address(venue),
            abi.encodeCall(CheapVenueModule.pay, (child, sub, HOLD, merchant, keccak256("two"))),
            10_000_000
        );
        assertFalse(ok, "paid with ample gas");
        _scan(address(venue), data, ICrestVault.CounterpartyNotAllowed.selector);
    }

    /// The same venue with the root's list switched to yes: the payment lands, so the scenario itself works.
    function test_theCheapVenueModulePaysWhenEveryListSaysYes() public {
        CheapVenueModule venue = new CheapVenueModule(address(usdc));
        vm.prank(principal);
        vault.setModule(address(venue), address(venue), "");
        (CrestVault child,) = _agentChild(2 * HOLD);
        _setList(vault, agentGrant, principal, address(0));
        _setList(vault, ROOT, principal, address(new YesList()));
        uint256 before = usdc.balanceOf(address(venue));
        venue.pay(child, sub, HOLD, makeAddr("a merchant"), keccak256("one"));
        assertEq(usdc.balanceOf(address(venue)) - before, HOLD);
    }

    /// The margin, measured (see `_margin`) for the cheap venue's child payment. Fails today with the attack below:
    /// the margin is negative, and the downward search itself lands a payment inside the window.
    function test_gas_theCheapVenuesMarginAboveAStarvedList() public {
        CheapVenueModule venue = new CheapVenueModule(address(usdc));
        vm.prank(principal);
        vault.setModule(address(venue), address(venue), "");
        usdc.mint(address(venue), 1);
        (CrestVault child,) = _agentChild(2 * HOLD);
        _setList(vault, agentGrant, principal, address(0));
        address merchant = makeAddr("a merchant");
        _margin(address(venue), abi.encodeCall(CheapVenueModule.pay, (child, sub, HOLD, merchant, keccak256("one"))));
    }

    function test_gas_theCheapVenuesTopVaultMarginAboveAStarvedList() public {
        CheapVenueModule venue = new CheapVenueModule(address(usdc));
        vm.prank(principal);
        vault.setModule(address(venue), address(venue), "");
        usdc.mint(address(venue), 1);
        _setList(vault, agentGrant, principal, address(0));
        address merchant = makeAddr("a merchant");
        _margin(address(venue), abi.encodeCall(CheapVenueModule.pay, (vault, buyer, HOLD, merchant, keccak256("one"))));
    }

    function test_gas_aHoldbackTopVaultPaymentsMarginAboveAStarvedList() public {
        _margin(address(module), _fundCall(_vterms(address(vault), buyer), BUYER_PK));
    }

    function test_gas_aHoldbackChildPaymentsMarginAboveAStarvedList() public {
        (CrestVault child,) = _agentChild(2 * HOLD);
        _margin(address(module), _fundCall(_vterms(address(child), sub), SUB_PK));
    }

    /// Measured, not asserted: the least gas with which `data` lands when the root's list says yes, against the least
    /// gas with which the root's list gets its whole cap. A negative margin is a window in which a payment lands while
    /// its last list runs short of its cap.
    function _margin(address target, bytes memory data) internal {
        uint256 lands = _leastLanding(target, data);
        _starveRootExactly();
        uint256 full = _leastRefusedByName(target, data, ICrestVault.CounterpartyNotAllowed.selector);
        emit log_named_uint("least gas the payment lands with, every list yes", lands);
        emit log_named_uint("least gas the root's list gets its whole cap with", full);
        emit log_named_int("margin, gas (negative: a window)", int256(lands) - int256(full));
    }

    /// A child vault pays through the cheapest venue module, and the root's list says no with its whole cap and yes
    /// with any less. The agent sends the payment with gas just above the least that lands: the list runs a few hundred
    /// gas short, says yes, and the payment to a merchant the list refuses lands. Fails today: `_listAllows`
    /// (`src/CrestVault.sol:494`) asks for 30,000 gas but does not make sure the list gets it, and after a child's last
    /// list call (inside the parent's `checkPath`, `src/CrestVault.sol:281`) this module needs less than a full cap.
    function test_attack_aListShortOfItsCapByAFewHundredGas_paysThroughACheapVenue() public {
        CheapVenueModule venue = new CheapVenueModule(address(usdc));
        vm.prank(principal);
        vault.setModule(address(venue), address(venue), "");
        usdc.mint(address(venue), 1);
        (CrestVault child,) = _agentChild(2 * HOLD);
        _setList(vault, agentGrant, principal, address(0));
        address merchant = makeAddr("a merchant the root refuses");
        bytes memory data = abi.encodeCall(CheapVenueModule.pay, (child, sub, HOLD, merchant, keccak256("one")));
        uint256 lands = _leastLanding(address(venue), data);
        _starveRootExactly();
        (bool ample,) = _callGas(address(venue), data, 10_000_000);
        assertFalse(ample, "paid with ample gas");
        uint256 before = usdc.balanceOf(address(venue));
        for (uint256 g = lands - 500; g <= lands + 1500; ++g) {
            (bool ok,) = _callGas(address(venue), data, g);
            if (ok) {
                emit log_named_uint("paid a merchant the list refuses, with gas", g);
                emit log_named_uint("amount paid", usdc.balanceOf(address(venue)) - before);
                fail();
                return;
            }
        }
    }

    /// A realistic list that fails open when it cannot reach its blocklist, on the agent's grant: the banned
    /// counterparty is never paid.
    function test_attack_starvingAFailOpenBlocklist_neverPaysTheBannedCounterparty() public {
        _scan(address(module), _blocklisted(), ICrestVault.CounterpartyNotAllowed.selector);
    }

    /// `checkPath` says it reverts as `charge` would. With a list whose answer depends on its gas, a low-gas
    /// `checkPath` passes for a counterparty the payment refuses: a simulation, or a contract that gates on
    /// `checkPath` with a gas limit, is told yes. Fails today: `_listAllows` (`src/CrestVault.sol:494`) does not
    /// make sure the list got its whole cap.
    function test_attack_aLowGasCheckPathAgreesWithThePayment() public {
        _starveRoot();
        _expectRefused(_vterms(address(vault), buyer), BUYER_PK, _refusedAt(ROOT));
        bytes memory data = abi.encodeCall(ICrestVault.checkPath, (agentGrant, HOLD, _merchant()));
        uint256 passedAt;
        for (uint256 g = 1000; g <= 64_000; g += 16) {
            (bool ok,) = _callGas(address(vault), data, g);
            if (ok) {
                passedAt = g;
                break;
            }
        }
        emit log_named_uint("checkPath passed with gas", passedAt);
        assertEq(passedAt, 0, "checkPath passed for a counterparty the payment refuses");
    }

    /// The same with the realistic list: a fail-open blocklist list on the agent's grant, and the banned counterparty.
    function test_attack_aLowGasCheckPathAgreesWithThePayment_failOpenBlocklist() public {
        _blocklisted();
        _expectRefused(_unlisted(address(vault), buyer), BUYER_PK, _refusedAt(agentGrant));
        bytes memory data = abi.encodeCall(ICrestVault.checkPath, (agentGrant, HOLD, _unlistedCp()));
        uint256 passedAt;
        for (uint256 g = 1000; g <= 64_000; g += 16) {
            (bool ok,) = _callGas(address(vault), data, g);
            if (ok) {
                passedAt = g;
                break;
            }
        }
        emit log_named_uint("checkPath passed for the banned counterparty with gas", passedAt);
        assertEq(passedAt, 0, "checkPath passed for a counterparty the payment refuses");
    }
}

/// The fail-open blocklist at random gas values in the starvation window, the window found once in `setUp`.
contract RedTeamListStarvationFuzzTest is StarvationBase {
    bytes internal fundData;
    uint256 internal top;

    function setUp() public override {
        super.setUp();
        fundData = _blocklisted();
        top = _leastRefusedByName(address(module), fundData, ICrestVault.CounterpartyNotAllowed.selector);
    }

    function testFuzz_attack_starvingAFailOpenBlocklist_neverPays(uint256 below) public {
        uint256 g = top - bound(below, 0, top > WINDOW ? WINDOW : top);
        (bool ok,) = _callGas(address(module), fundData, g);
        assertFalse(ok, "a banned counterparty was paid");
    }
}
