// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {PayModule} from "../mocks/PayModule.sol";
import {MockERC3009Token} from "commerce-payments-test/mocks/MockERC3009Token.sol";

/// Drives random payments, ends and time through a tree (root, agent, two sub-agents) and remembers what was paid.
contract TreeHandler is Test {
    CrestVault public vault;
    PayModule public module;
    MockERC3009Token public token;
    address public immutable agent = makeAddr("agent");
    address public immutable subA = makeAddr("sub A");
    address public immutable subB = makeAddr("sub B");
    bytes32 public constant LISTED = keccak256("listed merchant");
    bytes32 public constant UNLISTED = keccak256("unlisted merchant");

    uint256 public paidTotal;
    mapping(address => uint256) public paidBy;
    bytes32[] public opens;
    mapping(bytes32 => bool) public isOpen;
    uint256 public paymentsPastALimit;

    constructor(CrestVault v, PayModule m, MockERC3009Token t) {
        (vault, module, token) = (v, m, t);
    }

    function pay(uint8 who, uint256 amount, bool listed) external {
        address k = who % 3 == 0 ? agent : who % 3 == 1 ? subA : subB;
        amount = bound(amount, 1, 200);
        try module.pay(vault, k, amount, listed ? LISTED : UNLISTED) returns (bytes32 c) {
            paidTotal += amount;
            paidBy[k] += amount;
            opens.push(c);
            isOpen[c] = true;
            // A payment that went through respects every per-payment limit on its path.
            uint256 g = vault.grantOf(k);
            for (; g != 0; g = vault.getGrant(g).parent) {
                ICrestVault.Grant memory x = vault.getGrant(g);
                if (amount > x.caps.perSpend) paymentsPastALimit++;
                if (x.caps.restricted && !listed) paymentsPastALimit++;
            }
        } catch {}
    }

    function end(uint256 i) external {
        if (opens.length == 0) return;
        bytes32 c = opens[bound(i, 0, opens.length - 1)];
        if (!isOpen[c]) return;
        module.end(vault, c);
        isOpen[c] = false;
    }

    function wait(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
    }
}

/// Whatever the sequence, no grant passes any of its limits, every level counts what passes through it, and no money
/// leaves the vault except to the pinned payee.
contract TreeInvariantsTest is Test {
    uint256 internal constant ROOT = 1;
    uint256 internal constant LOADED = 1_000_000;
    CrestVault internal vault;
    PayModule internal module;
    MockERC3009Token internal token;
    TreeHandler internal h;
    uint256 internal agentGrant;
    uint256 internal subAGrant;
    uint256 internal subBGrant;

    function setUp() public {
        vm.warp(1_790_000_000);
        token = new MockERC3009Token("Mock USDC", "mUSDC", 6);
        CrestFactory factory = new CrestFactory(0, address(0));
        address principal = makeAddr("principal");
        vault = CrestVault(factory.create(principal, address(token), 0));
        module = new PayModule(address(token));
        h = new TreeHandler(vault, module, token);
        vm.startPrank(principal);
        vault.setModule(address(module), address(module), "");
        agentGrant = vault.grant(ROOT, h.agent(), _caps(100, 300, 1_000, 3, true, true), 0, "");
        vault.allow(agentGrant, h.LISTED(), true, "");
        vm.stopPrank();
        vm.startPrank(h.agent());
        subAGrant = vault.grant(
            agentGrant,
            h.subA(),
            _caps(type(uint128).max, type(uint128).max, type(uint128).max, type(uint32).max, false, false),
            0,
            ""
        );
        subBGrant = vault.grant(agentGrant, h.subB(), _caps(50, 200, 400, 2, false, false), 0, "");
        vm.stopPrank();
        token.mint(address(vault), LOADED);
        targetContract(address(h));
    }

    function _caps(
        uint256 perSpend,
        uint256 perPeriod,
        uint256 lifetime,
        uint32 maxOpen,
        bool restricted,
        bool mayDelegate
    ) internal pure returns (ICrestVault.Caps memory) {
        return ICrestVault.Caps(
            uint128(perSpend), uint128(perPeriod), uint128(lifetime), maxOpen, 1 days, 0, restricted, mayDelegate
        );
    }

    function _g(uint256 id) internal view returns (ICrestVault.Grant memory) {
        return vault.getGrant(id);
    }

    function invariant_noGrantPassesItsTotalOrItsPeriod() public view {
        uint256[4] memory ids = [ROOT, agentGrant, subAGrant, subBGrant];
        for (uint256 i; i < ids.length; i++) {
            ICrestVault.Grant memory g = _g(ids[i]);
            assertLe(g.spent, g.caps.lifetime);
            assertLe(g.inPeriod, g.caps.perPeriod);
            assertLe(g.open, g.caps.maxOpen);
        }
    }

    function invariant_everyLevelCountsWhatPassesThroughIt() public view {
        assertEq(_g(subAGrant).spent, h.paidBy(h.subA()));
        assertEq(_g(subBGrant).spent, h.paidBy(h.subB()));
        assertEq(_g(agentGrant).spent, h.paidTotal(), "the agent's grant counts its own and its sub-agents' payments");
        assertEq(_g(ROOT).spent, h.paidTotal());
        assertEq(_g(agentGrant).open, _g(subAGrant).open + _g(subBGrant).open + _ownOpen(), "open counts add up");
        assertEq(_g(ROOT).open, _g(agentGrant).open);
    }

    function invariant_aChildNeverPassesItsParent() public view {
        assertLe(_g(subAGrant).spent + _g(subBGrant).spent, _g(agentGrant).spent);
        assertLe(_g(agentGrant).spent, _g(agentGrant).caps.lifetime);
    }

    function invariant_everyPaymentThatPassedWasInsideItsLimits() public view {
        assertEq(h.paymentsPastALimit(), 0);
    }

    function invariant_moneyGoesOnlyToThePinnedPayee() public view {
        assertEq(token.balanceOf(address(vault)) + token.balanceOf(address(module)), LOADED);
        assertEq(token.balanceOf(address(module)), h.paidTotal());
    }

    /// The agent's own open commitments: its total less its sub-agents'.
    function _ownOpen() internal view returns (uint32) {
        return _g(agentGrant).open - _g(subAGrant).open - _g(subBGrant).open;
    }
}
