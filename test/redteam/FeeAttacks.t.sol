// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {MockERC3009Token} from "commerce-payments-test/mocks/MockERC3009Token.sol";
import {Vm} from "forge-std/Vm.sol";
import {HoldbackRules} from "holdback/HoldbackRules.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestFeeSweeper} from "../../src/CrestFeeSweeper.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestFeeSweeper} from "../../src/ICrestFeeSweeper.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {HoldbackModule} from "../../src/modules/holdback/HoldbackModule.sol";
import {IReceiveWithAuthorization, PayModule} from "../mocks/PayModule.sol";
import {RedTeamBase, RogueOperator} from "./RedTeamBase.sol";

/// A module the principal enabled, its own payee. It approves two payments before it pulls either, or answers one
/// ERC-3009 authorization for two commitments.
contract RedBatchModule {
    address public immutable TOKEN;

    constructor(address token) {
        TOKEN = token;
    }

    function chargeBothThenPull(ICrestVault v, address controller, uint256 a1, uint256 a2) external {
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 c1 = keccak256(abi.encode(address(v), "first"));
        bytes32 c2 = keccak256(abi.encode(address(v), "second"));
        v.charge(controller, a1, bytes32(0), c1, validBefore, c1);
        v.charge(controller, a2, bytes32(0), c2, validBefore, c2);
        IReceiveWithAuthorization(TOKEN).receiveWithAuthorization(address(v), address(this), a1, 0, validBefore, c1, "");
        IReceiveWithAuthorization(TOKEN).receiveWithAuthorization(address(v), address(this), a2, 0, validBefore, c2, "");
    }

    function chargeOneAuthorizationTwice(ICrestVault v, address controller, uint256 a) external {
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256(abi.encode(address(v), "one authorization"));
        v.charge(controller, a, bytes32(0), keccak256("commitment one"), validBefore, nonce);
        v.charge(controller, a, bytes32(0), keccak256("commitment two"), validBefore, nonce);
        IReceiveWithAuthorization(TOKEN).receiveWithAuthorization(
            address(v), address(this), a, 0, validBefore, nonce, ""
        );
    }
}

/// A vault in name only. The sweeper asks it for a token and has it pay; it may re-enter the sweep with a real vault.
contract RedFakeVault {
    address public token;
    CrestFeeSweeper internal _sweeper;
    ICrestVault internal _real;

    constructor(address token_, CrestFeeSweeper sweeper_, ICrestVault real_) {
        (token, _sweeper, _real) = (token_, sweeper_, real_);
    }

    function collectFee() external returns (uint256) {
        if (address(_real) != address(0)) _sweeper.sweep(_real);
        return 0;
    }
}

/// A test token that calls back any contract it pays, after the transfer.
contract RedCallbackToken is MockERC3009Token {
    constructor() MockERC3009Token("Callback USD", "cUSD", 6) {}

    function _afterTokenTransfer(address, address to, uint256) internal override {
        if (to.code.length != 0) {
            (bool ok,) = to.call(abi.encodeWithSignature("onTokens()"));
            ok;
        }
    }
}

/// A fee destination that re-enters the sweeper and the vault whenever it is paid.
contract RedReenteringDestination {
    CrestFeeSweeper public sweeper;
    ICrestVault public vault;
    uint256 public calls;

    function aim(CrestFeeSweeper s, ICrestVault v) external {
        (sweeper, vault) = (s, v);
    }

    function onTokens() external {
        if (calls++ >= 3) return;
        vault.collectFee();
        sweeper.sweep(vault);
    }
}

/// A test token whose `balanceOf` reports a chosen figure for chosen accounts; transfers use the real balances.
contract RedLyingToken is MockERC3009Token {
    mapping(address => bool) public lies;
    mapping(address => uint256) public shown;

    constructor() MockERC3009Token("Lying USD", "lUSD", 6) {}

    function lieAbout(address who, uint256 shown_) external {
        (lies[who], shown[who]) = (true, shown_);
    }

    function balanceOf(address owner) public view override returns (uint256) {
        return lies[owner] ? shown[owner] : super.balanceOf(owner);
    }

    function realBalanceOf(address owner) external view returns (uint256) {
        return super.balanceOf(owner);
    }
}

/// The deploy script with the chain, the rules contract and the fee set by the test, so it reads no RPC and no
/// environment variable.
contract RedFeeDeployHarness is Deploy {
    uint256 internal _bps;
    address internal _feeSweeper;
    HoldbackRules internal _rules;

    function set(HoldbackRules rules_, uint256 bps_, address feeSweeper_) external {
        (_rules, _bps, _feeSweeper) = (rules_, bps_, feeSweeper_);
    }

    function rpcChainId() public pure override returns (uint256) {
        return 31_337;
    }

    function rulesFor(uint256) public view override returns (HoldbackRules) {
        return _rules;
    }

    function feeOf() public view override returns (uint256, address) {
        return (_bps, _feeSweeper);
    }

    function recordPath(uint256) public pure override returns (string memory) {
        return "deployments/rehearsal-fee-red-team.json";
    }
}

/// Red team on the fee (Crest PR 8): money leaving a vault by a path the fee opens, a payment or a stop blocked by it,
/// and a limit passed through it. Every `test_attack_*` and `test_neutrality_*` passes when the defence holds and fails
/// when the attack works.
contract RedTeamFeeTest is RedTeamBase {
    uint256 internal constant RATE = 100; // 1%, in basis points
    uint256 internal constant CREST_FEE = HOLD * RATE / 10_000;

    address internal destination;
    CrestFeeSweeper internal sweeper;
    CrestFactory internal feeFactory;
    CrestVault internal fv;
    uint256 internal fg;

    function setUp() public override {
        super.setUp();
        destination = makeAddr("fee destination");
        sweeper = new CrestFeeSweeper(destination);
        feeFactory = new CrestFactory(RATE, address(sweeper));
        fv = CrestVault(feeFactory.create(principal, address(usdc), bytes32("red team fee vault")));
        vm.startPrank(principal);
        fv.setModule(address(module), module.payee(), "");
        fg = fv.grant(ROOT, buyer, _caps(2 * HOLD, 3 * (HOLD + CREST_FEE), type(uint128).max, 5, true, true), 0, "");
        allowList.set(fv, fg, _merchant(), true, "");
        vm.stopPrank();
        usdc.mint(address(fv), 10 * HOLD);
    }

    // 1. Money leaving the vault, and the fee owed

    /// A module the principal enabled approves two payments, then pulls both. Each `charge` checks the balance before
    /// any pull, so the second check counts money the first payment is about to take, and the vault ends short of the
    /// fee it owes.
    function test_attack_twoApprovalsBeforeAnyPull_leaveTheVaultShortOfItsFee() public {
        (CrestVault v,,) = _payWorld(feeFactory, address(usdc), bytes32("batch"));
        RedBatchModule batch = new RedBatchModule(address(usdc));
        _enable(v, address(batch));
        uint256 a = 1_000_000;
        uint256 fee = a * RATE / 10_000;
        usdc.mint(address(v), 2 * a + fee); // both payments and one of their two fees
        bool landed;
        try batch.chargeBothThenPull(v, buyer, a, a) {
            landed = true;
        } catch {}
        uint256 held = usdc.balanceOf(address(v));
        uint256 owed = v.feeOwed();
        emit log_named_uint("observed: the batch landed (1) or was refused (0)", landed ? 1 : 0);
        emit log_named_uint("observed: balance left, base units", held);
        emit log_named_uint("observed: feeOwed, base units", owed);
        (bool collected,) = address(v).call(abi.encodeCall(ICrestVault.collectFee, ()));
        emit log_named_uint("observed: collectFee went through (1) or reverted (0)", collected ? 1 : 0);
        vm.prank(principal);
        (bool withdrew,) = address(v).call(abi.encodeCall(ICrestVault.withdraw, (principal, 0, "")));
        emit log_named_uint("observed: a withdrawal of 0 went through (1) or reverted (0)", withdrew ? 1 : 0);
        assertGe(held, owed, "the vault holds at least the fee it owes");
    }

    /// A module answers one ERC-3009 authorization for two commitments. Only one payment can leave, because the token
    /// spends a nonce once, but the vault counts two fees and two payments against the grant.
    function test_attack_oneAuthorizationChargedTwice_owesOneFee() public {
        (CrestVault v,, uint256 g) = _payWorld(feeFactory, address(usdc), bytes32("one authorization"));
        RedBatchModule batch = new RedBatchModule(address(usdc));
        _enable(v, address(batch));
        uint256 a = 1_000_000;
        usdc.mint(address(v), 10 * a);
        uint256 before = usdc.balanceOf(address(v));
        try batch.chargeOneAuthorizationTwice(v, buyer, a) {} catch {}
        uint256 left = before - usdc.balanceOf(address(v));
        uint256 feeOfWhatLeft = left * RATE / 10_000;
        emit log_named_uint("observed: paid out, base units", left);
        emit log_named_uint("observed: the grant's spent, base units", _grantOf(v, g).spent);
        assertEq(v.feeOwed(), feeOfWhatLeft, "the vault owes the fee of what left, and no more");
        assertEq(_grantOf(v, g).spent, left + feeOfWhatLeft, "the grant counts what left, with its fee");
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_attack_collectFeeMovesExactlyTheFeeOwed_onlyToTheSweeper(uint64 a1, uint64 a2, address caller)
        public
    {
        (CrestVault v, PayModule pay,) = _payWorld(feeFactory, address(usdc), bytes32("collect"));
        vm.assume(caller != address(v) && caller != address(sweeper) && caller != address(vm));
        usdc.mint(address(v), 2 * (uint256(a1) + a2) + 1);
        pay.pay(v, buyer, a1, bytes32(0));
        pay.pay(v, buyer, a2, bytes32(0));
        uint256 owed = uint256(a1) * RATE / 10_000 + uint256(a2) * RATE / 10_000;
        assertEq(v.feeOwed(), owed, "the vault owes exactly its payments' fees");
        uint256 vaultBefore = usdc.balanceOf(address(v));
        uint256 sweeperBefore = usdc.balanceOf(address(sweeper));
        uint256 callerBefore = usdc.balanceOf(caller);
        vm.prank(caller);
        assertEq(v.collectFee(), owed);
        assertEq(vaultBefore - usdc.balanceOf(address(v)), owed, "the vault paid exactly the fee owed");
        assertEq(usdc.balanceOf(address(sweeper)) - sweeperBefore, owed, "the fixed sweeper got it");
        assertEq(usdc.balanceOf(caller), callerBefore, "the caller got nothing");
        assertEq(v.feeOwed(), 0);
        vm.prank(caller);
        assertEq(v.collectFee(), 0, "a second collection pays nothing");
    }

    /// A refund, the end of the commitment and a reclaim after the escrow's expiry each bring money back or close the
    /// books, and none owes a fee. Each payment's own fee stays owed.
    function test_attack_aRefundAReclaimOrAnEndOwesNoNewFee() public {
        H.Terms memory t = _vterms(address(fv), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        _deliver(t, id);
        rules.decide(t, _primary(t, id, H.OUTCOME_REJECT), _noDelivery(), "");
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Refunded));
        assertEq(fv.feeOwed(), CREST_FEE, "the refund owes nothing new; the payment's own fee stays owed");
        module.close(t);
        assertEq(fv.feeOwed(), CREST_FEE, "ending the commitment owes nothing");

        H.Terms memory t2 = _vterms(address(fv), buyer);
        bytes32 id2 = _fundVia(t2, BUYER_PK);
        _deliver(t2, id2);
        vm.warp(uint256(t2.timing.fallbackBy) + t2.timing.appealDecideSec + rules.EXPIRY_MARGIN());
        uint256 before = usdc.balanceOf(address(fv));
        vm.prank(stranger);
        fv.reclaim(address(module), _pi(t2));
        assertEq(usdc.balanceOf(address(fv)) - before, HOLD, "the reclaim brought the hold back");
        assertEq(fv.feeOwed(), 2 * CREST_FEE, "the reclaim owes nothing new");

        uint256 all = usdc.balanceOf(address(fv));
        vm.prank(principal);
        vm.expectRevert(ICrestVault.BalanceBelowFee.selector);
        fv.withdraw(principal, all, "");
        vm.prank(principal);
        fv.withdraw(principal, all - 2 * CREST_FEE, "all but the fees owed");
        assertEq(fv.collectFee(), 2 * CREST_FEE);
        assertEq(usdc.balanceOf(address(fv)), 0);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_attack_aWithdrawalAFillOrAReturnOwesNoFee(uint256 fill, uint256 back, uint256 out) public {
        vm.prank(principal);
        fv.setCaps(fg, _wide(), "");
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        vm.prank(buyer);
        CrestVault child = CrestVault(fv.createChild(fg, 0, ""));
        uint256 free = usdc.balanceOf(address(fv)) - CREST_FEE;
        fill = bound(fill, 0, free);
        vm.prank(buyer);
        fv.fundChild(address(child), fill, "");
        back = bound(back, 0, fill);
        vm.prank(principal);
        fv.takeBackFromChild(address(child), back, "");
        out = bound(out, 0, free - fill + back);
        vm.prank(principal);
        fv.withdraw(principal, out, "");
        assertEq(fv.feeOwed(), CREST_FEE, "only the payment owes a fee");
        assertEq(child.feeOwed(), 0, "a fill and a return owe none");
        assertEq(usdc.balanceOf(address(fv)), CREST_FEE + free - fill + back - out);
    }

    /// An operator of the shared escrow relays an honest funding from the fee vault, then presents its own payment in
    /// the same transaction. Its payment lands nowhere, and the vault still covers its fee.
    function test_attack_anOperatorPaysInsideTheFundingTransaction_leavesTheFeeCovered() public {
        RogueOperator rogue = new RogueOperator(escrow);
        H.Terms memory t = _vterms(address(fv), buyer);
        bytes memory relayed = _fundCall(t, BUYER_PK);
        AuthCaptureEscrow.PaymentInfo memory pi = _piAs(t, address(rogue), buyer);
        bool paid = rogue.relayThenPay(address(module), relayed, pi, address(collector3009), new bytes(65));
        assertFalse(paid, "another operator's payment drew on the vault");
        assertEq(fv.feeOwed(), CREST_FEE);
        assertGe(usdc.balanceOf(address(fv)), fv.feeOwed(), "the vault holds at least the fee it owes");
    }

    // 2. Blocking a payment, a withdrawal or a stop

    /// The token refuses every transfer to the sweeper, as a token can block an address. Only collecting stops:
    /// payments, a release, a refund, a take-back, a pause, a close and a withdrawal of the money above the fee go on.
    function test_neutrality_aSweeperTheTokenRefuses_blocksNoPaymentWithdrawalOrStop() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(fv.createChild(fg, 0, ""));
        vm.prank(buyer);
        fv.fundChild(address(child), HOLD, "");
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(usdc.transfer.selector, address(sweeper)), "blocked");

        H.Terms memory t1 = _vterms(address(fv), buyer);
        bytes32 id1 = _fundVia(t1, BUYER_PK);
        vm.expectRevert();
        fv.collectFee();
        vm.expectRevert();
        sweeper.sweep(fv);
        assertEq(fv.feeOwed(), CREST_FEE, "the fee waits in the vault");

        H.Terms memory t2 = _vterms(address(fv), buyer);
        bytes32 id2 = _fundVia(t2, BUYER_PK);
        assertEq(fv.feeOwed(), 2 * CREST_FEE, "payments go on");

        uint256 sellerBefore = usdc.balanceOf(seller);
        _release(t1, id1);
        assertEq(usdc.balanceOf(seller) - sellerBefore, PRICE, "the release pays the seller");
        _deliver(t2, id2);
        rules.decide(t2, _primary(t2, id2, H.OUTCOME_REJECT), _noDelivery(), "");
        assertEq(uint8(_stage(id2)), uint8(IHoldbackRules.Stage.Refunded), "the refund lands");

        vm.startPrank(principal);
        fv.takeBackFromChild(address(child), HOLD, "a take-back");
        fv.setPaused(fg, true, "a stop");
        fv.close(fg, "a stop");
        fv.withdraw(principal, usdc.balanceOf(address(fv)) - 2 * CREST_FEE, "everything above the fee");
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(fv)), 2 * CREST_FEE);

        vm.clearMockedCalls();
        sweeper.sweep(fv);
        assertEq(usdc.balanceOf(destination), 2 * CREST_FEE, "the fee is collected once the token allows it");
    }

    /// A stranger can neither raise `feeOwed` nor shrink the money above it: `charge` takes only an enabled module, and
    /// collecting moves the fee and the balance by the same amount.
    function test_attack_aStrangerRaisesTheFeeOrShrinksTheMoneyAboveIt_refused() public {
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        uint256 free = usdc.balanceOf(address(fv)) - fv.feeOwed();
        bytes32 merchant = _merchant();
        vm.prank(stranger);
        vm.expectRevert(ICrestVault.ModuleNotEnabled.selector);
        fv.charge(buyer, HOLD, merchant, keccak256("a stranger's commitment"), block.timestamp + 1, bytes32(0));
        vm.prank(stranger);
        fv.collectFee();
        vm.prank(stranger);
        sweeper.sweep(fv);
        assertEq(usdc.balanceOf(address(fv)) - fv.feeOwed(), free, "collecting moves no money above the fee");
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        assertEq(fv.feeOwed(), CREST_FEE, "the next payment owes its own fee only");
    }

    /// The vault owes nothing, and the token's `balanceOf` says 0 for it. At a rate of 0 the principal withdraws; at a
    /// rate above 0 the fee check asks the token first.
    function test_attack_aBalanceOfThatSaysZero_blocksNoWithdrawalWhileNothingIsOwed() public {
        RedLyingToken t = new RedLyingToken();
        CrestVault atZero = CrestVault(factory.create(principal, address(t), bytes32("lying token, rate 0")));
        CrestVault withFee = CrestVault(feeFactory.create(principal, address(t), bytes32("lying token, a fee")));
        t.mint(address(atZero), 1_000);
        t.mint(address(withFee), 1_000);
        t.lieAbout(address(atZero), 0);
        t.lieAbout(address(withFee), 0);
        vm.prank(principal);
        atZero.withdraw(principal, 1_000, "rate 0");
        assertEq(withFee.feeOwed(), 0, "nothing is owed");
        vm.prank(principal);
        withFee.withdraw(principal, 1_000, "nothing is owed");
        assertEq(t.realBalanceOf(principal), 2_000);
    }

    /// Out of scope, token-issuer risk: a token that says the vault holds more than it does passes the check, and a
    /// withdrawal of the real balance takes the fee owed with it. No vault check can catch a token that lies about its
    /// own balances; the principal chooses the token.
    function test_observe_aBalanceOfThatSaysMore_isTheTokensRisk() public {
        RedLyingToken t = new RedLyingToken();
        (CrestVault v, PayModule pay,) = _payWorld(feeFactory, address(t), bytes32("lying token says more"));
        t.mint(address(v), 2_000_000);
        pay.pay(v, buyer, 1_000_000, bytes32(0));
        uint256 owed = v.feeOwed();
        uint256 real = t.realBalanceOf(address(v));
        t.lieAbout(address(v), real + owed);
        vm.prank(principal);
        v.withdraw(principal, real, "everything");
        assertEq(t.realBalanceOf(address(v)), 0, "the lying token let the fee owed leave");
        assertEq(v.feeOwed(), owed, "the vault still records what it owes");
    }

    // 3. A limit passed through the fee

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_attack_noLimitIsPassedThroughTheFee(
        uint16 rate,
        uint64 perSpend,
        uint64 perPeriod,
        uint64 lifetime,
        uint64[6] memory amounts
    ) public {
        rate = uint16(bound(rate, 1, 10_000));
        CrestFactory f = new CrestFactory(rate, address(sweeper));
        MockERC3009Token t = new MockERC3009Token("Limit USD", "LUSD", 6);
        (CrestVault v, PayModule pay, uint256 g) = _payWorld(f, address(t), bytes32("limits"));
        ICrestVault.Caps memory c = _wide();
        (c.perSpend, c.perPeriod, c.lifetime) = (perSpend, perPeriod, lifetime);
        vm.prank(principal);
        v.setCaps(g, c, "");
        t.mint(address(v), 12 * uint256(type(uint64).max));
        uint256 left;
        uint256 fees;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 a = bound(amounts[i], 0, uint256(perSpend) + 1);
            uint256 fee = a * rate / 10_000;
            try pay.pay(v, buyer, a, bytes32(0)) {
                assertLe(a + fee, perSpend, "a payment with its fee stays within the per-payment limit");
                left += a;
                fees += fee;
            } catch {}
        }
        assertEq(v.feeOwed(), fees, "the vault owes exactly its payments' fees");
        assertLe(left + fees, perPeriod, "everything that leaves stays within the period limit");
        assertLe(left + fees, lifetime, "and within the lifetime limit");
        assertEq(_grantOf(v, g).spent, left + fees, "the grant counted every payment with its fee");
    }

    /// At 100 bps a payment of 99 base units owes 0. Ten of them meet the period limit, and the eleventh is refused.
    function test_attack_paymentsWhoseFeeRoundsToZero_passNoLimit() public {
        (CrestVault v, PayModule pay, uint256 g) = _payWorld(feeFactory, address(usdc), bytes32("small"));
        vm.prank(principal);
        v.setCaps(g, _caps(99, 990, type(uint128).max, type(uint32).max, false, true), "");
        usdc.mint(address(v), 10_000);
        for (uint256 i; i < 10; ++i) {
            pay.pay(v, buyer, 99, bytes32(0));
        }
        assertEq(v.feeOwed(), 0, "observed: a payment under 10,000 / rate base units owes nothing");
        assertEq(_grantOf(v, g).inPeriod, 990);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, g));
        pay.pay(v, buyer, 1, bytes32(0));
    }

    /// The largest amount a vault can name, at the lowest rate: the payment and its fee pass 128 bits. The design says a
    /// payment that meets a limit is refused by name once its fee is counted.
    function test_attack_theLargestAmountWithAFee_isRefusedByName() public {
        CrestFactory f = new CrestFactory(1, address(sweeper));
        MockERC3009Token t = new MockERC3009Token("Big USD", "BUSD", 6);
        (CrestVault v, PayModule pay, uint256 g) = _payWorld(f, address(t), bytes32("largest"));
        t.mint(address(v), type(uint256).max / 2);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, g));
        pay.pay(v, buyer, type(uint128).max, bytes32(0));
    }

    /// At 10,000 bps the largest payment whose sum with its fee fits 128 bits: the payee gets exactly the amount, and
    /// the fee stays in the vault until the sweeper collects it.
    function test_attack_theLargestAmountThatFitsWithItsFee_movesExactlyItsTerms() public {
        CrestFactory f = new CrestFactory(10_000, address(sweeper));
        MockERC3009Token t = new MockERC3009Token("Big USD", "BUSD", 6);
        (CrestVault v, PayModule pay, uint256 g) = _payWorld(f, address(t), bytes32("largest that fits"));
        uint256 a = type(uint128).max / 2;
        t.mint(address(v), 2 * a);
        pay.pay(v, buyer, a, bytes32(0));
        assertEq(v.feeOwed(), a);
        assertEq(t.balanceOf(address(pay)), a, "the payee got exactly the amount");
        assertEq(t.balanceOf(address(v)), a, "the fee stays in the vault");
        assertEq(_grantOf(v, g).spent, 2 * a);
        assertEq(v.collectFee(), a);
        assertEq(t.balanceOf(address(sweeper)), a);
        assertEq(t.balanceOf(address(v)), 0);
    }

    /// A child vault of the fee factory pays a hold through the module its top vault enabled. The parent's per-payment
    /// limit counts the fee, the paying vault owes it once, and nothing more leaves the parent.
    function test_attack_aChildVaultPaysThroughTheTopModule_oneFee_countedByTheParentsLimit() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(fv.createChild(fg, 0, ""));
        vm.prank(buyer);
        fv.fundChild(address(child), 2 * HOLD, "");
        vm.prank(buyer);
        uint256 subGrant = child.grant(ROOT, sub, _wide(), 0, "");
        uint256 topBalance = usdc.balanceOf(address(fv));
        uint256 fgSpent = _grantOf(fv, fg).spent;

        vm.prank(principal);
        fv.setCaps(fg, _caps(HOLD, 10 * HOLD, type(uint128).max, 5, true, true), "one hold, no room for its fee");
        _expectRefused(
            _vterms(address(child), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, fg)
        );

        vm.prank(principal);
        fv.setCaps(fg, _caps(HOLD + CREST_FEE, 10 * HOLD, type(uint128).max, 5, true, true), "one hold and its fee");
        _fundVia(_vterms(address(child), sub), SUB_PK);
        assertEq(child.feeOwed(), CREST_FEE, "the paying vault owes the fee");
        assertEq(fv.feeOwed(), 0, "the parent owes none");
        assertEq(usdc.balanceOf(address(fv)), topBalance, "nothing left the parent");
        assertEq(_grantOf(fv, fg).spent, fgSpent, "the parent's grant counted the fill only");
        assertEq(_grantOf(child, subGrant).spent, HOLD + CREST_FEE);
        assertEq(usdc.balanceOf(address(child)), HOLD, "the hold left; the fee waits in the child");
    }

    /// A grandchild pays: the fee is owed once, in the grandchild, and the middle vault's per-payment limit counts it.
    function test_attack_aGrandchildPays_oneFee_countedAtEveryLevelAbove() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(fv.createChild(fg, 0, ""));
        vm.prank(buyer);
        fv.fundChild(address(child), 2 * HOLD, "");
        vm.prank(buyer);
        uint256 subGrant = child.grant(ROOT, sub, _wide(), 0, "");
        vm.prank(sub);
        CrestVault grandchild = CrestVault(child.createChild(subGrant, 0, ""));
        vm.prank(sub);
        child.fundChild(address(grandchild), HOLD + CREST_FEE, "");

        vm.prank(buyer);
        child.setCaps(
            subGrant, _caps(HOLD, type(uint128).max, type(uint128).max, 5, false, true), "no room for the fee"
        );
        _expectRefused(
            _vterms(address(grandchild), sub),
            SUB_PK,
            abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, subGrant)
        );

        vm.prank(buyer);
        child.setCaps(subGrant, _caps(HOLD + CREST_FEE, type(uint128).max, type(uint128).max, 5, false, true), "");
        _fundVia(_vterms(address(grandchild), sub), SUB_PK);
        assertEq(grandchild.feeOwed(), CREST_FEE, "the paying vault owes the fee");
        assertEq(child.feeOwed(), 0);
        assertEq(fv.feeOwed(), 0);
        assertEq(usdc.balanceOf(address(grandchild)), CREST_FEE, "only the fee is left in the grandchild");
        assertEq(_grantOf(grandchild, ROOT).spent, HOLD + CREST_FEE);
    }

    /// Three payments meet the period limit with their fees. A shorter period carries the window to its own end, and a
    /// sub-grant with a period of its own changes nothing: the agent's grant still counts every fee.
    function test_attack_aPeriodChangeLetsNoFeePassTheLimit() public {
        for (uint256 i; i < 3; ++i) {
            _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        }
        assertEq(_grantOf(fv, fg).inPeriod, 3 * (HOLD + CREST_FEE));
        ICrestVault.Caps memory c = _caps(2 * HOLD, 3 * (HOLD + CREST_FEE), type(uint128).max, 5, true, true);
        c.period = 1 hours;
        vm.prank(principal);
        fv.setCaps(fg, c, "a shorter period");
        _expectRefused(
            _vterms(address(fv), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, fg)
        );
        ICrestVault.Caps memory s = _wide();
        s.period = 1 minutes;
        vm.prank(buyer);
        fv.grant(fg, sub, s, 0, "");
        _expectRefused(
            _vterms(address(fv), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, fg)
        );
    }

    // 4. The hold

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_attack_theHoldReceivesExactlyItsTerms_atAnyRate(uint16 rate) public {
        rate = uint16(bound(rate, 0, 10_000));
        CrestFactory f = new CrestFactory(rate, rate == 0 ? address(0) : address(sweeper));
        CrestVault v = CrestVault(f.create(principal, address(usdc), bytes32("any rate")));
        vm.startPrank(principal);
        v.setModule(address(module), module.payee(), "");
        v.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
        uint256 fee = HOLD * rate / 10_000;
        usdc.mint(address(v), HOLD + fee);
        if (fee != 0) {
            vm.prank(principal);
            v.withdraw(principal, 1, "one base unit short of the hold and its fee");
            _expectRefused(
                _vterms(address(v), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.BalanceBelowFee.selector)
            );
            usdc.mint(address(v), 1);
        }
        H.Terms memory t = _vterms(address(v), buyer);
        uint256 store = _held(t);
        bytes32 id = _fundVia(t, BUYER_PK);
        assertEq(_held(t) - store, HOLD, "the hold holds exactly its terms");
        assertEq(v.feeOwed(), fee);
        assertEq(usdc.balanceOf(address(v)), fee, "only the fee is left");
        uint256 sellerBefore = usdc.balanceOf(seller);
        _release(t, id);
        assertEq(usdc.balanceOf(seller) - sellerBefore, PRICE, "the seller gets the price");
        assertEq(usdc.balanceOf(address(v)), fee, "the release takes nothing from the vault");
    }

    // 5. The sweeper

    /// A fake vault passed to `sweep` re-enters it with a real vault. The real vault pays its fee once, and all of it
    /// reaches the fixed destination.
    function test_attack_aFakeVaultPassedToSweep_movesOnlyTheRealFee_onlyToTheDestination() public {
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        uint256 vaultBefore = usdc.balanceOf(address(fv));
        RedFakeVault fake = new RedFakeVault(address(usdc), sweeper, ICrestVault(address(fv)));
        vm.prank(stranger);
        sweeper.sweep(ICrestVault(address(fake)));
        assertEq(usdc.balanceOf(destination), CREST_FEE, "the destination got the real vault's fee, once");
        assertEq(vaultBefore - usdc.balanceOf(address(fv)), CREST_FEE, "the vault paid only its fee");
        assertEq(usdc.balanceOf(address(fake)), 0);
        assertEq(usdc.balanceOf(address(sweeper)), 0);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    /// A stranger has the vault pay the sweeper directly, then sweeps a fake vault. The sweeper's record of the sweep
    /// must credit a vault only with what that vault paid.
    function test_attack_theSweepRecordCreditsOnlyTheVaultThatPaid() public {
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        vm.prank(stranger);
        fv.collectFee();
        RedFakeVault fake = new RedFakeVault(address(usdc), sweeper, ICrestVault(address(0)));
        vm.recordLogs();
        vm.prank(stranger);
        uint256 forwarded = sweeper.sweep(ICrestVault(address(fake)));
        assertEq(forwarded, CREST_FEE, "observed: the sweep forwards whatever the sweeper holds");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(sweeper) && logs[i].topics[0] == ICrestFeeSweeper.Swept.selector) {
                seen = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(fake));
                assertEq(abi.decode(logs[i].data, (uint256)), 0, "the record credits the fake vault with no fee");
            }
        }
        assertTrue(seen, "the sweep left a record");
    }

    /// The destination is a contract that re-enters the vault and the sweeper each time it is paid. It gets the fee
    /// owed and nothing more, and the vault pays it once.
    function test_attack_aDestinationThatReentersTheSweep_getsOnlyTheFeeOwed() public {
        RedCallbackToken t = new RedCallbackToken();
        RedReenteringDestination dest = new RedReenteringDestination();
        CrestFeeSweeper s = new CrestFeeSweeper(address(dest));
        CrestFactory f = new CrestFactory(RATE, address(s));
        (CrestVault v, PayModule pay,) = _payWorld(f, address(t), bytes32("re-entry"));
        dest.aim(s, ICrestVault(address(v)));
        t.mint(address(v), 10_000_000);
        pay.pay(v, buyer, 1_000_000, bytes32(0));
        pay.pay(v, buyer, 2_000_000, bytes32(0));
        uint256 owed = v.feeOwed();
        uint256 before = t.balanceOf(address(v));
        s.sweep(ICrestVault(address(v)));
        assertGt(dest.calls(), 0, "the destination re-entered");
        assertEq(t.balanceOf(address(dest)), owed, "the destination got the fee owed, once");
        assertEq(before - t.balanceOf(address(v)), owed, "the vault paid only its fee");
        assertEq(t.balanceOf(address(s)), 0);
        assertEq(v.feeOwed(), 0);
    }

    function test_attack_theSweepersFunctions_areExactlyTheReviewedList() public view {
        string[] memory got =
            vm.parseJsonKeys(vm.readFile("out/CrestFeeSweeper.sol/CrestFeeSweeper.json"), ".methodIdentifiers");
        assertEq(got.length, 2, "the sweeper's function count changed");
        assertEq(got[0], "DESTINATION()");
        assertEq(got[1], "sweep(address)");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_attack_anySelectorOutsideTheSweepersList_reverts(
        bytes4 selector,
        bytes calldata rest,
        address caller
    ) public {
        vm.assume(selector != sweeper.DESTINATION.selector && selector != sweeper.sweep.selector);
        vm.prank(caller);
        (bool ok,) = address(sweeper).call(abi.encodePacked(selector, rest));
        assertFalse(ok, "a selector outside the list ran");
    }

    // 6. The rate and the sweeper are fixed

    function test_attack_noSignerAltersTheRateOrTheSweeper() public {
        CrestVault impl = CrestVault(feeFactory.IMPLEMENTATION());
        vm.prank(stranger);
        vm.expectRevert(ICrestVault.AlreadyInitialized.selector);
        impl.initialize(stranger, address(usdc), address(0), 0);
        vm.prank(stranger);
        vm.expectRevert(ICrestVault.AlreadyInitialized.selector);
        fv.initialize(stranger, address(usdc), address(0), 0);
        vm.prank(principal);
        fv.proposePrincipal(stranger, "");
        vm.prank(stranger);
        fv.acceptPrincipal("");
        assertEq(fv.FEE_BPS(), RATE);
        assertEq(fv.FEE_SWEEPER(), address(sweeper));
        assertEq(impl.FEE_BPS(), RATE);
        assertEq(impl.FEE_SWEEPER(), address(sweeper));
        assertEq(sweeper.DESTINATION(), destination);
    }

    /// The design: two events, only when there is a fee. A collection of nothing, from a rate-0 vault or from a fee
    /// vault that owes nothing, leaves no fee record.
    function test_attack_aCollectionOfNothing_leavesNoFeeRecord() public {
        vm.recordLogs();
        vm.prank(stranger);
        vault.collectFee();
        vm.prank(stranger);
        fv.collectFee();
        assertEq(vm.getRecordedLogs().length, 0, "no FeeCollected for a collection of nothing");
    }

    // 7. The deploy script

    function test_attack_theScriptsAddressForAFeeFactory_isWhereItDeploys() public {
        RedFeeDeployHarness script = new RedFeeDeployHarness();
        script.set(rules, RATE, address(sweeper));
        (CrestFactory pf, HoldbackModule pm) = script.addresses(rules);
        (CrestFactory f, HoldbackModule m) = script.run();
        assertEq(address(f), address(pf));
        assertEq(address(m), address(pm));
        CrestVault impl = CrestVault(f.IMPLEMENTATION());
        assertEq(impl.FEE_BPS(), RATE);
        assertEq(impl.FEE_SWEEPER(), address(sweeper));
        RedFeeDeployHarness zero = new RedFeeDeployHarness();
        zero.set(rules, 0, address(0));
        (CrestFactory zf,) = zero.addresses(rules);
        assertTrue(address(zf) != address(f), "another fee gives another factory address");
    }

    function test_attack_theScriptRefusesAFeeWithASweeperThatHasNoCode() public {
        RedFeeDeployHarness script = new RedFeeDeployHarness();
        script.set(rules, RATE, makeAddr("a key, not a sweeper"));
        vm.expectRevert(abi.encodeWithSelector(Deploy.CheckFailed.selector, "a fee needs a sweeper contract"));
        script.run();
    }

    /// Any contract passes the script's check. Here the sweeper is the token itself, which has no way to move on what
    /// it receives, so every fee collected would stay there for good.
    function test_attack_theScriptRefusesAFeeWithAContractThatIsNotASweeper() public {
        RedFeeDeployHarness script = new RedFeeDeployHarness();
        script.set(rules, RATE, address(usdc));
        vm.expectRevert();
        script.run();
    }

    function test_attack_theScriptRefusesARateAboveTheWhole() public {
        RedFeeDeployHarness script = new RedFeeDeployHarness();
        script.set(rules, 10_001, address(sweeper));
        vm.expectRevert();
        script.run();
    }

    // Helpers

    /// A vault of `f` for `token`, with `buyer` holding a grant with no limits and a `PayModule` that is its own payee.
    function _payWorld(CrestFactory f, address token, bytes32 s)
        internal
        returns (CrestVault v, PayModule pay, uint256 g)
    {
        v = CrestVault(f.create(principal, token, s));
        pay = new PayModule(token);
        vm.startPrank(principal);
        v.setModule(address(pay), address(pay), "");
        g = v.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
    }

    function _enable(CrestVault v, address m) internal {
        vm.prank(principal);
        v.setModule(m, m, "");
    }
}
