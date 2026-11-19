// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

// The review of the fee (T-554): the limits the first tests left out, the token and the sweeper, the sweeper's own
// selector and opcode checks, the deploy script's fee path, and what its findings changed.

import {MockERC3009Token} from "commerce-payments-test/mocks/MockERC3009Token.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestFeeSweeper} from "../../src/CrestFeeSweeper.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestFeeSweeper} from "../../src/ICrestFeeSweeper.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {HoldbackModule} from "../../src/modules/holdback/HoldbackModule.sol";
import {CrestBase} from "../CrestBase.sol";
import {DeployHarness} from "../Deploy.t.sol";
import {IReceiveWithAuthorization, PayModule} from "../mocks/PayModule.sol";

/// A token whose `transfer` answers false, without reverting, to one recipient.
contract FalseToken is MockERC3009Token {
    address public refused;

    constructor() MockERC3009Token("False USD", "fUSD", 6) {}

    function refuse(address who) external {
        refused = who;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to != address(0) && to == refused) return false;
        return super.transfer(to, amount);
    }
}

/// A module that has the vault approve two payments before it pulls either.
contract BatchModule {
    address public immutable TOKEN;

    constructor(address token) {
        TOKEN = token;
    }

    function payTwice(ICrestVault vault, address controller, uint256 amount, bytes32 counterparty) external {
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 c1 = keccak256(abi.encode(address(vault), "one"));
        bytes32 c2 = keccak256(abi.encode(address(vault), "two"));
        vault.charge(controller, amount, counterparty, c1, validBefore, c1);
        vault.charge(controller, amount, counterparty, c2, validBefore, c2);
        IReceiveWithAuthorization(TOKEN).receiveWithAuthorization(
            address(vault), address(this), amount, 0, validBefore, c1, ""
        );
        IReceiveWithAuthorization(TOKEN).receiveWithAuthorization(
            address(vault), address(this), amount, 0, validBefore, c2, ""
        );
    }
}

/// Not a vault: it names a token and pays nothing when asked for its fee.
contract NotAVault {
    address public token;

    constructor(address token_) {
        token = token_;
    }

    function collectFee() external pure returns (uint256) {
        return 0;
    }
}

contract FeeReviewTest is CrestBase {
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
        fv = CrestVault(feeFactory.create(principal, address(usdc), bytes32("a vault with a fee")));
        vm.startPrank(principal);
        fv.setModule(address(module), module.payee(), "");
        fg = fv.grant(ROOT, buyer, _caps(2 * HOLD, 10 * HOLD, type(uint128).max, 5, true, true), 0, "");
        fv.allow(fg, _merchant(), true, "");
        vm.stopPrank();
        usdc.mint(address(fv), 10 * HOLD);
    }

    // Limits: the cases the PR's tests leave out

    /// A child vault's payment that exactly meets the parent grant's per-payment limit is refused in the parent vault
    /// once its fee is counted: the parent's `checkPath` must get the payment with its fee.
    function test_attack_aChildPaymentExactlyAtTheParentGrantsPerPaymentLimit_refusedByName() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(fv.createChild(fg, 0, ""));
        vm.prank(buyer);
        fv.fundChild(address(child), 3 * HOLD, "");
        vm.prank(buyer);
        child.grant(ROOT, sub, _wide(), 0, "");
        vm.prank(principal);
        fv.setCaps(fg, _caps(HOLD, 10 * HOLD, type(uint128).max, 5, true, true), "per payment: exactly one hold");
        _expectRefused(
            _vterms(address(child), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, fg)
        );
        vm.prank(principal);
        fv.setCaps(fg, _caps(HOLD + CREST_FEE, 10 * HOLD, type(uint128).max, 5, true, true), "one hold and its fee");
        _fundVia(_vterms(address(child), sub), SUB_PK);
        assertEq(child.feeOwed(), CREST_FEE, "the child owes its payment's fee");
        assertEq(fv.feeOwed(), 0, "the parent owes nothing for its child's payment");
    }

    function test_attack_aPaymentExactlyAtTheLifetimeLimit_withAFee_refusedByName() public {
        vm.prank(principal);
        fv.setCaps(fg, _caps(type(uint128).max, type(uint128).max, HOLD, 5, true, true), "a total of one hold");
        _expectRefused(
            _vterms(address(fv), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.OverLifetime.selector, fg)
        );
        vm.prank(principal);
        fv.setCaps(fg, _caps(type(uint128).max, type(uint128).max, HOLD + CREST_FEE, 5, true, true), "and its fee");
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        assertEq(_grantOf(fv, fg).spent, HOLD + CREST_FEE);
    }

    // The sweeper and the token

    /// Criterion 5, the half the PR leaves out: a token that answers false on the forward.
    function test_aForwardTheTokenAnswersFalse_leavesPaymentsUntouched() public {
        FalseToken t = new FalseToken();
        (CrestVault v, PayModule pay) = _tokenWorld(address(t), address(sweeper));
        pay.pay(v, buyer, 1_000_000, keccak256("anyone"));
        uint256 owed = v.feeOwed();
        assertGt(owed, 0);
        t.refuse(destination);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        sweeper.sweep(ICrestVault(address(v)));
        assertEq(v.feeOwed(), owed, "the fee is still owed");
        pay.pay(v, buyer, 1_000_000, keccak256("anyone"));
        assertEq(v.feeOwed(), 2 * owed, "payments go on");
        t.refuse(address(0));
        sweeper.sweep(ICrestVault(address(v)));
        assertEq(t.balanceOf(destination), 2 * owed);
    }

    /// A sweeper the token will not pay: `collectFee` fails, and nothing else does.
    function test_attack_aSweeperTheTokenRefuses_blocksNoPaymentWithdrawalOrStop() public {
        FalseToken t = new FalseToken();
        (CrestVault v, PayModule pay) = _tokenWorld(address(t), address(sweeper));
        pay.pay(v, buyer, 1_000_000, keccak256("anyone"));
        t.refuse(address(sweeper));
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        v.collectFee();
        pay.pay(v, buyer, 1_000_000, keccak256("anyone"));
        uint256 owed = v.feeOwed();
        uint256 free = t.balanceOf(address(v)) - owed;
        uint256 g = v.grantOf(buyer);
        vm.startPrank(principal);
        v.withdraw(principal, free, "everything above the fee owed");
        v.setPaused(g, true, "stop");
        v.close(g, "stop for good");
        vm.stopPrank();
        assertEq(t.balanceOf(principal), free);
        assertEq(t.balanceOf(address(v)), owed, "only the fee owed stays");
    }

    function test_theSweepersFunctions_areExactlyTheReviewedList() public view {
        string[2] memory want = ["DESTINATION()", "sweep(address)"];
        string[] memory got =
            vm.parseJsonKeys(vm.readFile("out/CrestFeeSweeper.sol/CrestFeeSweeper.json"), ".methodIdentifiers");
        assertEq(got.length, want.length, "the sweeper's function count changed");
        for (uint256 i; i < want.length; i++) {
            assertEq(got[i], want[i]);
        }
    }

    function test_defense_noSelfdestructCallcodeOrDelegatecall_inTheSweeper() public view {
        bytes memory code = address(sweeper).code;
        assertEq(_count(code, 0xff), 0, "SELFDESTRUCT");
        assertEq(_count(code, 0xf2), 0, "CALLCODE");
        assertEq(_count(code, 0xf4), 0, "DELEGATECALL");
    }

    // What the findings changed

    /// A module that has the vault approve two payments before it pulls either is refused at the second, so the fee
    /// owed never exceeds the balance.
    function test_attack_twoChargesBeforeEitherPull_refused() public {
        MockERC3009Token t = new MockERC3009Token("Mock USD", "mUSD", 6);
        CrestFactory f = new CrestFactory(RATE, address(sweeper));
        CrestVault v = CrestVault(f.create(principal, address(t), bytes32("batch")));
        BatchModule batch = new BatchModule(address(t));
        vm.startPrank(principal);
        v.setModule(address(batch), address(batch), "");
        v.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
        uint256 amount = 1_000_000;
        uint256 fee = amount * RATE / 10_000;
        t.mint(address(v), 2 * amount + fee);
        vm.expectRevert(ICrestVault.ApprovalPending.selector);
        batch.payTwice(v, buyer, amount, keccak256("anyone"));
        assertEq(v.feeOwed(), 0);
        assertEq(t.balanceOf(address(v)), 2 * amount + fee);
    }

    /// `sweep` given a contract that is not a vault forwards fees the sweeper already holds, and records 0 for that
    /// contract. The money goes only to the destination.
    function test_observe_aContractThatIsNotAVault_isNamedInSwept() public {
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        fv.collectFee();
        NotAVault other = new NotAVault(address(usdc));
        vm.expectEmit(address(sweeper));
        emit ICrestFeeSweeper.Swept(address(other), address(usdc), 0, stranger);
        vm.prank(stranger);
        sweeper.sweep(ICrestVault(address(other)));
        assertEq(usdc.balanceOf(destination), CREST_FEE);
    }

    /// At 10,000 bps a payment above half of `type(uint128).max` cannot carry its fee: refused by name.
    function test_attack_theTopRateNearTheLargestAmount_refusedByName() public {
        MockERC3009Token t = new MockERC3009Token("Mock USD", "mUSD", 6);
        CrestFactory f = new CrestFactory(10_000, address(sweeper));
        CrestVault v = CrestVault(f.create(principal, address(t), bytes32("top")));
        PayModule pay = new PayModule(address(t));
        vm.startPrank(principal);
        v.setModule(address(pay), address(pay), "");
        uint256 g = v.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, g));
        pay.pay(v, buyer, uint256(type(uint128).max / 2) + 1, keccak256("anyone"));
    }

    /// A hold refunded after funding returns its price; the fee its payment owed stays owed (open for the maintainer).
    function test_observe_aRefundedHoldLeavesItsFeeOwed() public {
        H.Terms memory t = _vterms(address(fv), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        _deliver(t, id);
        rules.decide(t, _primary(t, id, H.OUTCOME_REJECT), _noDelivery(), "");
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Refunded));
        assertEq(fv.feeOwed(), CREST_FEE, "the fee of a refunded payment stays owed");
    }

    /// The fee events come only when there is a fee: `collectFee` with nothing owed emits nothing.
    function test_atRateZero_collectFeeEmitsNothing() public {
        vm.recordLogs();
        vm.prank(stranger);
        assertEq(vault.collectFee(), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // Helpers

    function _tokenWorld(address t, address feeSweeper) internal returns (CrestVault v, PayModule pay) {
        CrestFactory f = new CrestFactory(RATE, feeSweeper);
        v = CrestVault(f.create(principal, t, bytes32("review")));
        pay = new PayModule(t);
        vm.startPrank(principal);
        v.setModule(address(pay), address(pay), "");
        v.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
        MockERC3009Token(t).mint(address(v), 100_000_000);
    }

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
}

/// The deploy script with the fee set by the test.
contract FeeDeployHarness is DeployHarness {
    uint256 public bps;
    address public feeTo;

    function setFee(uint256 bps_, address feeTo_) external {
        (bps, feeTo) = (bps_, feeTo_);
    }

    function feeOf() public view override returns (uint256, address) {
        return (bps, feeTo);
    }
}

/// The deploy script's fee path, which the PR's deploy tests run only at a rate of 0.
contract FeeDeployReviewTest is CrestBase {
    FeeDeployHarness internal script;

    function setUp() public override {
        super.setUp();
        script = new FeeDeployHarness();
        script.set(31_337, rules);
    }

    function test_attack_aDeployWithAFeeAndASweeperWithNoCode_refused() public {
        script.setFee(100, makeAddr("a key, not a contract"));
        vm.expectRevert(abi.encodeWithSelector(Deploy.CheckFailed.selector, "a fee needs a sweeper contract"));
        script.run();
    }

    function test_aDeployWithAFee_landsAtItsPredictedAddress_andCarriesTheFee() public {
        CrestFeeSweeper s = new CrestFeeSweeper(makeAddr("fee destination"));
        script.setFee(100, address(s));
        (CrestFactory pf,) = script.addresses(rules);
        (CrestFactory f, HoldbackModule m) = script.run();
        assertEq(address(f), address(pf));
        CrestVault impl = CrestVault(f.IMPLEMENTATION());
        assertEq(impl.FEE_BPS(), 100);
        assertEq(impl.FEE_SWEEPER(), address(s));
        script.setFee(200, address(s));
        vm.expectRevert(abi.encodeWithSelector(Deploy.CheckFailed.selector, "the factory's fee is not the one asked"));
        script.check(f, m, rules);
        script.setFee(0, address(0));
        (CrestFactory zero,) = script.addresses(rules);
        assertTrue(address(zero) != address(f), "another fee is another factory");
    }
}
