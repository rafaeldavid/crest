// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {PayModule} from "../mocks/PayModule.sol";

interface IFiatToken {
    function balanceOf(address) external view returns (uint256);
    function version() external view returns (string memory);
    function authorizationState(address, bytes32) external view returns (bool);
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) external;
}

/// Circle's USDC on a fork of Sepolia, a proxy whose implementation checks ERC-1271 through an external library: a
/// vault pays through a module whose pinned payee is itself, so the token asks the vault, and the vault answers only
/// because the caller is the token's proxy address. Runs only when `CREST_FORK_URL` names a Sepolia RPC; skipped
/// otherwise, as in CI.
contract UsdcForkTest is Test {
    address internal constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    uint256 internal constant ROOT = 1;
    uint256 internal constant AMOUNT = 5_000_000; // 5 USDC

    CrestVault internal vault;
    PayModule internal module;
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");

    function setUp() public {
        string memory url = vm.envOr("CREST_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        CrestFactory factory = new CrestFactory();
        vault = CrestVault(factory.create(principal, USDC, 0));
        module = new PayModule(USDC);
        vm.startPrank(principal);
        vault.setModule(address(module), address(module), "");
        vault.grant(
            ROOT,
            agent,
            ICrestVault.Caps({
                perSpend: uint128(AMOUNT),
                perPeriod: uint128(3 * AMOUNT),
                lifetime: type(uint128).max,
                maxOpen: 10,
                period: 1 days,
                expiresAt: 0,
                restricted: false,
                mayDelegate: false
            }),
            0,
            ""
        );
        vm.stopPrank();
        deal(USDC, address(vault), 10 * AMOUNT);
    }

    function test_onSepoliaUsdc_theVaultPaysThroughTheTokensProxy() public {
        emit log_named_string("USDC version", IFiatToken(USDC).version());
        uint256 vaultBefore = IFiatToken(USDC).balanceOf(address(vault));
        bytes32 commitment = module.pay(vault, agent, AMOUNT, keccak256("anyone"));
        assertEq(vaultBefore - IFiatToken(USDC).balanceOf(address(vault)), AMOUNT, "the vault paid");
        assertEq(IFiatToken(USDC).balanceOf(address(module)), AMOUNT, "to the pinned payee");
        assertTrue(IFiatToken(USDC).authorizationState(address(vault), commitment), "the nonce is used");
        assertEq(vault.getGrant(vault.grantOf(agent)).spent, AMOUNT);
    }

    function test_onSepoliaUsdc_overThePerSpendLimit_refused() public {
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, vault.grantOf(agent)));
        module.pay(vault, agent, AMOUNT + 1, keccak256("anyone"));
    }

    /// Without a charge, the token's own ERC-3009 paths get no from the vault: a transfer authorization and a cancel
    /// that would burn a nonce.
    function test_onSepoliaUsdc_noTransferOrCancelWithoutACharge() public {
        bytes32 nonce = keccak256("grief");
        vm.expectRevert();
        IFiatToken(USDC).transferWithAuthorization(
            address(vault), address(this), AMOUNT, 0, block.timestamp + 1 hours, nonce, ""
        );
        vm.expectRevert();
        IFiatToken(USDC).cancelAuthorization(address(vault), nonce, "");
        assertFalse(IFiatToken(USDC).authorizationState(address(vault), nonce));
    }
}
