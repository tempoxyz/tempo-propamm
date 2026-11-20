// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { DeployManagedBufferHelpers } from "../../script/managed/DeployManagedBufferHelpers.s.sol";
import { DirectPropAMMBufferHelper } from "../../src/DirectPropAMMBufferHelper.sol";
import { IDirectPropAMM } from "../../src/interfaces/IDirectPropAMM.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";
import { VirtualAddress } from "../v2/utils/VirtualAddress.sol";
import { TestFeeHookLib } from "./utils/TestFeeHook.sol";

using TestFeeHookLib for ManagedDirectPropAMM;

/// @dev Reads its inputs from storage instead of the process environment, which parallel tests share.
contract DeployManagedBufferHelpersHarness is DeployManagedBufferHelpers {
    bytes internal _encoded;

    function setInput(Config calldata config) external {
        _encoded = abi.encode(config);
    }

    /// @notice The real environment reader, for the one test that sets the environment.
    function readEnvConfig() external view returns (Config memory) {
        return super._readConfig();
    }

    function _readConfig() internal view override returns (Config memory) {
        return abi.decode(_encoded, (Config));
    }
}

/// @dev A contract account standing in for a BoringVault: the script only needs it to have code.
contract ScriptVault {
    function name() external pure returns (string memory) {
        return "vault";
    }
}

/// @dev A Veda Teller as the script reads it: the BoringVault it serves and its Accountant.
contract ScriptTeller {
    address public vault;
    address public accountant = address(0xACC0);

    constructor(address vault_) {
        vault = vault_;
    }
}

/// @dev Answers `pairCount` and `MAX_BATCH` like a v2 `Venue`, but has no `tokenPairCount`.
contract VenueShaped {
    function pairCount() external pure returns (uint256) {
        return 2;
    }

    function MAX_BATCH() external pure returns (uint256) {
        return 100;
    }
}

contract DeployManagedBufferHelpersTest is Test {
    uint256 internal constant MAINNET = 4217;
    uint256 internal constant MODERATO = 42431;
    uint256 internal constant PRICE = 105_000_000;
    bytes32 internal constant ID_A = keccak256("vault-a");
    bytes32 internal constant ID_B = keccak256("vault-b");
    uint64 internal constant PARTNER = 7;
    uint16 internal constant PRIME_PAIR = 1;

    DeployManagedBufferHelpersHarness internal script;
    address internal deployer = makeAddr("deployer");
    address internal partner = makeAddr("partner");
    MockTIP20 internal prime;
    MockTIP20 internal usdy;
    MockTIP20 internal usdc;
    ManagedDirectPropAMM internal pool;
    address internal vaultA;
    address internal vaultB;
    MockOracle internal usdyOracle;
    MockOracle internal primeOracle;
    mapping(address vault => address teller) internal tellerOf;

    function setUp() external {
        vm.warp(1_000_000);
        vm.chainId(MODERATO);
        script = new DeployManagedBufferHelpersHarness();
        prime = new MockTIP20("PRIME", 6);
        usdy = new MockTIP20("USDY", 6);
        usdc = new MockTIP20("USDC.e", 6);
        vaultA = address(new ScriptVault());
        vaultB = address(new ScriptVault());
        tellerOf[vaultA] = address(new ScriptTeller(vaultA));
        tellerOf[vaultB] = address(new ScriptTeller(vaultB));
        usdyOracle = new MockOracle(18, 1.137e18, block.timestamp);
        primeOracle = new MockOracle(8, PRICE, block.timestamp);
        pool = new ManagedDirectPropAMM(address(this), address(0));
        // Pair 0 is USDY/USDC.e, pair 1 PRIME/USDC.e: both share the quote token.
        pool.addPair(address(usdy), address(usdc), usdyOracle, 90_000, 50);
        assertEq(pool.addPair(address(prime), address(usdc), primeOracle, 90_000, 50), 1);
        pool.addSponsor(PARTNER, partner);
        pool.setPairSponsor(PRIME_PAIR, PARTNER, true);
        // Vault A is on the PRIME pair's home list, vault B on the partner's list there.
        pool.setMembers(PRIME_PAIR, 0, _one(vaultA), true);
        vm.prank(partner);
        pool.setMembers(PRIME_PAIR, PARTNER, _one(vaultB), true);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
    }

    function test_deploysOneManagedHelperPerVaultAndPair() external {
        DeployManagedBufferHelpers.Config memory c = _config(2);
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);
        c.helpers[1] = _helper(vaultB, PRIME_PAIR, address(prime), PARTNER, ID_B, 25);
        script.setInput(c);
        uint64 nonce = vm.getNonce(deployer);

        address[] memory helpers = script.run();

        assertEq(helpers.length, 2);
        assertEq(vm.getNonce(deployer), nonce + 2, "one CREATE per helper and nothing else");
        assertEq(script.warnings().length, 0);
        for (uint256 i; i < 2; ++i) {
            DirectPropAMMBufferHelper helper = DirectPropAMMBufferHelper(helpers[i]);
            assertEq(helpers[i], vm.computeCreateAddress(deployer, nonce + i));
            assertTrue(helper.managed());
            assertEq(address(helper.pool()), address(pool));
            assertEq(helper.vault(), c.helpers[i].vault);
            assertEq(helper.pairIndex(), PRIME_PAIR);
            assertEq(helper.sponsorId(), c.helpers[i].sponsorId);
            assertEq(helper.baseToken(), address(prime));
            assertEq(helper.quoteToken(), address(usdc));
            assertEq(helper.customerId(), c.helpers[i].customerId);
            assertEq(helper.slippageBps(), c.helpers[i].slippageBps);
        }
        // Nothing but the helpers changed: the script lists nobody.
        assertFalse(pool.takerAllowed(PRIME_PAIR, helpers[0], 0));
        assertFalse(pool.takerAllowed(0, vaultA, 0));
    }

    /// @dev A helper can be deployed ahead of the vault's listing and of the hook review, but the run says so.
    function test_warnsAboutAVaultThePairDoesNotAdmitAndAboutAHook() external {
        DeployManagedBufferHelpers.Config memory c = _config(2);
        c.helpers[0] = _helper(vaultA, 0, address(usdy), 0, ID_A, 50);
        c.helpers[1] = _helper(vaultB, PRIME_PAIR, address(prime), 0, ID_B, 50);
        script.setInput(c);
        assertEq(script.run().length, 2);
        string[] memory warnings = script.warnings();
        assertEq(warnings.length, 2);
        assertEq(warnings[0], "Helper 0: the pair does not admit the vault now (vault not listed): its swaps revert");
        assertEq(warnings[1], "Helper 1: the pair does not admit the vault now (vault not listed): its swaps revert");

        pool.closePair(0);
        pool.configureFees(0, vaultA, 0, 0);
        // forge-lint: disable-next-line(unused-return)
        (address hook,) = pool.pairHook(0);
        c = _config(1);
        c.helpers[0] = _helper(vaultA, 0, address(usdy), 0, ID_A, 50);
        script.setInput(c);
        assertEq(script.run().length, 1);
        warnings = script.warnings();
        assertEq(warnings.length, 3, "the last run's warnings only");
        assertEq(warnings[0], "Helper 0: the pair does not admit the vault now (pair Closed): its swaps revert");
        // A Closed pair reads no list, so the pool's answer says nothing about it: the script reads it directly.
        assertEq(warnings[1], "Helper 0: the named list would refuse the vault on a Listed pair (vault not listed)");
        assertEq(
            warnings[2],
            string.concat(
                "Helper 0: the pair has a hook, ",
                vm.toString(hook),
                ": verify it charges the vault zero in both directions"
            )
        );
    }

    /// @dev The helper a Teller uses today names the vault and tokens the new one must keep.
    function test_theHelperItReplacesMustServeTheSameVaultAndTokens() external {
        address old = address(
            new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), vaultA, ID_A, 50, PRIME_PAIR, PARTNER)
        );
        DeployManagedBufferHelpers.Config memory c = _config(1);
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);
        c.helpers[0].replaced = old;
        script.setInput(c);
        assertEq(script.run().length, 1);
        assertEq(script.warnings().length, 0);

        c.helpers[0].customerId = ID_B;
        c.helpers[0].slippageBps = 25;
        script.setInput(c);
        assertEq(script.run().length, 1);
        string[] memory warnings = script.warnings();
        assertEq(warnings.length, 2);
        assertEq(warnings[0], "Helper 0: customer id differs from the helper it replaces");
        assertEq(warnings[1], "Helper 0: slippage differs from the helper it replaces (50 bps)");
        uint64 nonce = vm.getNonce(deployer);

        // Another vault's helper.
        pool.setMembers(PRIME_PAIR, 0, _one(vaultB), true);
        c.helpers[0] = _helper(vaultB, PRIME_PAIR, address(prime), 0, ID_B, 50);
        c.helpers[0].replaced = old;
        script.setInput(c);
        _expectInvalid("HELPER_REFERENCES[0] serves another vault");
        script.run();

        // The same vault's helper for another pair.
        c.helpers[0] = _helper(vaultA, 0, address(usdy), 0, ID_A, 50);
        c.helpers[0].replaced = old;
        script.setInput(c);
        _expectInvalid("HELPER_REFERENCES[0] serves other tokens");
        script.run();

        // Not a helper, and no code.
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);
        c.helpers[0].replaced = vaultB;
        script.setInput(c);
        _expectInvalid("HELPER_REFERENCES[0] is not a buffer helper");
        script.run();
        c.helpers[0].replaced = makeAddr("no code");
        script.setInput(c);
        _expectInvalid("HELPER_REFERENCES[0]");
        script.run();
        assertEq(vm.getNonce(deployer), nonce, "a refused run sends nothing");
    }

    function test_refusesAPairThatIsNotTheReviewedOne() external {
        DeployManagedBufferHelpers.Config memory c = _config(1);
        // The PRIME vault pointed at the USDY pair: the index is live, the tokens are not the reviewed ones.
        c.helpers[0] = _helper(vaultA, 0, address(prime), 0, ID_A, 50);
        script.setInput(c);
        _expectInvalid("HELPER_EXPECTED_BASES[0] is not the pair's base");
        script.run();

        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);
        c.helpers[0].expectedQuote = address(usdy);
        script.setInput(c);
        _expectInvalid("HELPER_EXPECTED_QUOTES[0] is not the pair's quote");
        script.run();

        c.helpers[0] = _helper(vaultA, 2, address(prime), 0, ID_A, 50);
        script.setInput(c);
        _expectInvalid("HELPER_PAIR_INDEXES[0] is not a pair");
        script.run();

        pool.closePair(PRIME_PAIR);
        pool.removePair(PRIME_PAIR);
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);
        script.setInput(c);
        _expectInvalid("HELPER_PAIR_INDEXES[0] was removed");
        script.run();
        assertEq(vm.getNonce(deployer), 0);
    }

    function test_refusesPoolsThatAreNotManaged() external {
        DeployManagedBufferHelpers.Config memory c = _config(1);
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);

        c.pool = IManagedDirectPropAMM(makeAddr("no code"));
        script.setInput(c);
        _expectInvalid("POOL_ADDRESS has no code");
        script.run();

        // No `pairCount`, as a `DirectPropAMM`; then a v2 venue's shape.
        c.pool = IManagedDirectPropAMM(vaultB);
        script.setInput(c);
        _expectInvalid("POOL_ADDRESS is not a ManagedDirectPropAMM");
        script.run();
        c.pool = IManagedDirectPropAMM(address(new VenueShaped()));
        script.setInput(c);
        _expectInvalid("POOL_ADDRESS is not a ManagedDirectPropAMM");
        script.run();
    }

    function test_refusesBadVaultsRoutesAndCounts() external {
        DeployManagedBufferHelpers.Config memory c = _config(1);
        address[4] memory bad = [address(0), address(pool), makeAddr("wallet"), VirtualAddress.make(1, 1)];
        for (uint256 i; i < bad.length; ++i) {
            c.helpers[0] = _helper(bad[i], PRIME_PAIR, address(prime), 0, ID_A, 50);
            script.setInput(c);
            _expectInvalid("HELPER_VAULTS[0]");
            script.run();
        }

        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, bytes32(0), 50);
        script.setInput(c);
        _expectInvalid("HELPER_CUSTOMER_IDS[0]");
        script.run();

        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 1001);
        script.setInput(c);
        _expectInvalid("HELPER_SLIPPAGE_BPS[0]");
        script.run();
        c.helpers[0].slippageBps = 1000;
        script.setInput(c);
        assertEq(script.run().length, 1, "the helper's own maximum");

        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(0), 0, ID_A, 50);
        script.setInput(c);
        _expectInvalid("HELPER_EXPECTED_BASES[0]");
        script.run();
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);
        c.helpers[0].expectedQuote = address(prime);
        script.setInput(c);
        _expectInvalid("HELPER_EXPECTED_QUOTES[0]");
        script.run();

        // One vault may hold helpers for two pairs, never two for one pair.
        c = _config(2);
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);
        c.helpers[1] = _helper(vaultA, 0, address(usdy), 0, ID_A, 50);
        script.setInput(c);
        assertEq(script.run().length, 2);
        c.helpers[1] = _helper(vaultA, PRIME_PAIR, address(prime), PARTNER, ID_B, 50);
        script.setInput(c);
        _expectInvalid("HELPER_VAULTS[1] repeats a vault and pair");
        script.run();

        script.setInput(_config(0));
        _expectInvalid("HELPER_* lists need 1 to 16 helpers");
        script.run();
        script.setInput(_config(17));
        _expectInvalid("HELPER_* lists need 1 to 16 helpers");
        script.run();
    }

    function test_refusesOtherChainsAndDeployers() external {
        DeployManagedBufferHelpers.Config memory c = _config(1);
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);
        script.setInput(c);
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployManagedBufferHelpers.UnexpectedChain.selector, 1));
        script.run();
        vm.chainId(MAINNET);
        assertEq(script.run().length, 1);

        address[3] memory bad = [address(0), 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, VirtualAddress.make(1, 1)];
        for (uint256 i; i < bad.length; ++i) {
            c.deployer = bad[i];
            script.setInput(c);
            _expectInvalid("DEPLOYER_ADDRESS");
            script.run();
        }
    }

    /// @dev A pool may hold several live pairs with the same two tokens, so the tokens alone do not name the pair:
    /// its oracle must be the reviewed one, and no other live pair may share all three.
    function test_refusesAnotherPairWithTheSameTokens() external {
        MockOracle other = new MockOracle(8, PRICE + 1, block.timestamp);
        assertEq(pool.addPair(address(prime), address(usdc), other, 90_000, 50), 2);
        pool.setMembers(2, 0, _one(vaultA), true);
        pool.setPairAccess(2, IManagedDirectPropAMM.AccessMode.Listed);

        // The other PRIME pair's index with the reviewed pair's tokens and oracle: live, admitted, and refused.
        DeployManagedBufferHelpers.Config memory c = _config(1);
        c.helpers[0] = _helper(vaultA, 2, address(prime), 0, ID_A, 50);
        script.setInput(c);
        _expectInvalid("HELPER_EXPECTED_ORACLES[0] is not the pair's oracle");
        script.run();
        // Naming that pair's own oracle is a reviewed choice of it, and the reviewed pair still deploys.
        c.helpers[0].expectedOracle = address(other);
        script.setInput(c);
        assertEq(script.run().length, 1);
        assertEq(script.warnings().length, 0);
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);
        script.setInput(c);
        assertEq(script.run().length, 1);
        uint64 nonce = vm.getNonce(deployer);

        c.helpers[0].expectedOracle = address(0);
        script.setInput(c);
        _expectInvalid("HELPER_EXPECTED_ORACLES[0]");
        script.run();

        // A twin holds the same tokens and oracle: nothing reviewed tells the two apart, whichever is named.
        assertEq(pool.addPair(address(prime), address(usdc), primeOracle, 90_000, 50), 3);
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);
        script.setInput(c);
        _expectInvalid("HELPER_PAIR_INDEXES[0] has a live twin pair");
        script.run();
        c.helpers[0].pairIndex = 3;
        script.setInput(c);
        _expectInvalid("HELPER_PAIR_INDEXES[0] has a live twin pair");
        script.run();
        assertEq(vm.getNonce(deployer), nonce, "a refused run sends nothing");

        // A removed twin is no longer live.
        pool.removePair(3);
        c.helpers[0].pairIndex = PRIME_PAIR;
        script.setInput(c);
        assertEq(script.run().length, 1);
    }

    /// @dev A managed helper being replaced names its pair: a replacement for another pair of the pool warns.
    function test_warnsWhenTheReplacedHelperServesAnotherPairOfThePool() external {
        MockOracle other = new MockOracle(8, PRICE + 1, block.timestamp);
        assertEq(pool.addPair(address(prime), address(usdc), other, 90_000, 50), 2);
        pool.setMembers(2, 0, _one(vaultA), true);
        pool.setPairAccess(2, IManagedDirectPropAMM.AccessMode.Listed);
        address old =
            address(new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), vaultA, ID_A, 50, PRIME_PAIR, 0));

        DeployManagedBufferHelpers.Config memory c = _config(1);
        c.helpers[0] = _helper(vaultA, 2, address(prime), 0, ID_A, 50);
        c.helpers[0].expectedOracle = address(other);
        c.helpers[0].replaced = old;
        script.setInput(c);
        assertEq(script.run().length, 1);
        string[] memory warnings = script.warnings();
        assertEq(warnings.length, 1);
        assertEq(warnings[0], "Helper 0: the helper it replaces serves pair 1 of this pool");
    }

    /// @dev The Teller the helper is meant for names the vault independently of the vault entry, on a first install
    /// too.
    function test_refusesATellerThatServesAnotherVault() external {
        pool.setMembers(PRIME_PAIR, 0, _one(vaultB), true);
        DeployManagedBufferHelpers.Config memory c = _config(1);
        // Vault B, admitted on the pair, entered for the helper meant for vault A's Teller.
        c.helpers[0] = _helper(vaultB, PRIME_PAIR, address(prime), 0, ID_A, 50);
        c.helpers[0].teller = tellerOf[vaultA];
        script.setInput(c);
        _expectInvalid("HELPER_TELLERS[0] serves another vault");
        script.run();

        // A vault is not a Teller, and neither is a buffer helper, which also answers vault().
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);
        c.helpers[0].teller = vaultB;
        script.setInput(c);
        _expectInvalid("HELPER_TELLERS[0] is not a Teller");
        script.run();
        c.helpers[0].teller =
            address(new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), vaultA, ID_A, 50, PRIME_PAIR, 0));
        script.setInput(c);
        _expectInvalid("HELPER_TELLERS[0] is not a Teller");
        script.run();

        address[3] memory bad = [address(0), vaultA, makeAddr("no code")];
        for (uint256 i; i < bad.length; ++i) {
            c.helpers[0].teller = bad[i];
            script.setInput(c);
            _expectInvalid("HELPER_TELLERS[0]");
            script.run();
        }
        assertEq(vm.getNonce(deployer), 0);
    }

    /// @dev An Open pair admits any caller without reading a list, so the pool's answer hides a list that would
    /// refuse the vault once the pair is Listed. The script reads the list itself.
    function test_warnsAboutAListThatWouldRefuseTheVaultOnAnOpenPair() external {
        pool.pause();
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Open);
        pool.unpause();
        string memory prefix = "Helper 0: the named list would refuse the vault on a Listed pair (";

        // On its home list: nothing to say.
        DeployManagedBufferHelpers.Config memory c = _config(1);
        script.setInput(c);
        assertEq(script.run().length, 1);
        assertEq(script.warnings().length, 0);

        // An unregistered sponsor id would be immutable in the helper.
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), 999, ID_A, 50);
        script.setInput(c);
        assertEq(script.run().length, 1);
        _assertOneWarning(string.concat(prefix, "unknown sponsor)"));

        // A registered, admitted sponsor that does not list the vault.
        c.helpers[0] = _helper(vaultA, PRIME_PAIR, address(prime), PARTNER, ID_A, 50);
        script.setInput(c);
        assertEq(script.run().length, 1);
        _assertOneWarning(string.concat(prefix, "vault not listed)"));

        // One that lists it but is not admitted on the pair, then one switched off.
        c.helpers[0] = _helper(vaultB, PRIME_PAIR, address(prime), PARTNER, ID_B, 50);
        script.setInput(c);
        assertEq(script.run().length, 1);
        assertEq(script.warnings().length, 0);
        pool.setPairSponsor(PRIME_PAIR, PARTNER, false);
        assertEq(script.run().length, 1);
        _assertOneWarning(string.concat(prefix, "sponsor not admitted)"));
        pool.setSponsorEnabled(PARTNER, false);
        assertEq(script.run().length, 1);
        _assertOneWarning(string.concat(prefix, "sponsor disabled)"));

        // On a Listed pair the pool's own answer is the list's refusal, reported once.
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        assertEq(script.run().length, 1);
        _assertOneWarning("Helper 0: the pair does not admit the vault now (sponsor disabled): its swaps revert");
    }

    function test_readsTheEnvironment() external {
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));
        vm.setEnv("POOL_ADDRESS", vm.toString(address(pool)));
        vm.setEnv("HELPER_VAULTS", string.concat(vm.toString(vaultA), ",", vm.toString(vaultB)));
        vm.setEnv("HELPER_TELLERS", string.concat(vm.toString(tellerOf[vaultA]), ",", vm.toString(tellerOf[vaultB])));
        vm.setEnv(
            "HELPER_EXPECTED_ORACLES",
            string.concat(vm.toString(address(primeOracle)), ",", vm.toString(address(usdyOracle)))
        );
        vm.setEnv("HELPER_PAIR_INDEXES", "1,0");
        vm.setEnv("HELPER_EXPECTED_BASES", string.concat(vm.toString(address(prime)), ",", vm.toString(address(usdy))));
        vm.setEnv("HELPER_EXPECTED_QUOTES", string.concat(vm.toString(address(usdc)), ",", vm.toString(address(usdc))));
        vm.setEnv("HELPER_SPONSOR_IDS", "0,7");
        vm.setEnv("HELPER_CUSTOMER_IDS", string.concat(vm.toString(ID_A), ",", vm.toString(ID_B)));
        vm.setEnv("HELPER_SLIPPAGE_BPS", "50,25");
        vm.setEnv("HELPER_REFERENCES", string.concat(vm.toString(address(0)), ",", vm.toString(vaultA)));
        DeployManagedBufferHelpers.Config memory c = script.readEnvConfig();
        assertEq(c.deployer, deployer);
        assertEq(address(c.pool), address(pool));
        assertEq(c.helpers.length, 2);
        assertEq(c.helpers[0].vault, vaultA);
        assertEq(c.helpers[0].teller, tellerOf[vaultA]);
        assertEq(c.helpers[1].teller, tellerOf[vaultB]);
        assertEq(c.helpers[0].expectedOracle, address(primeOracle));
        assertEq(c.helpers[1].expectedOracle, address(usdyOracle));
        assertEq(c.helpers[0].pairIndex, 1);
        assertEq(c.helpers[0].expectedBase, address(prime));
        assertEq(c.helpers[1].expectedBase, address(usdy));
        assertEq(c.helpers[1].expectedQuote, address(usdc));
        assertEq(c.helpers[1].sponsorId, 7);
        assertEq(c.helpers[1].customerId, ID_B);
        assertEq(c.helpers[1].slippageBps, 25);
        assertEq(c.helpers[0].replaced, address(0));
        assertEq(c.helpers[1].replaced, vaultA);

        vm.setEnv("HELPER_PAIR_INDEXES", "1,65536");
        _expectInvalid("HELPER_PAIR_INDEXES[1]");
        script.readEnvConfig();
        vm.setEnv("HELPER_PAIR_INDEXES", "1,0");
        vm.setEnv("HELPER_SPONSOR_IDS", "0,18446744073709551616");
        _expectInvalid("HELPER_SPONSOR_IDS[1]");
        script.readEnvConfig();
        vm.setEnv("HELPER_SPONSOR_IDS", "0,7");
        vm.setEnv("HELPER_SLIPPAGE_BPS", "50,65536");
        _expectInvalid("HELPER_SLIPPAGE_BPS[1]");
        script.readEnvConfig();
        vm.setEnv("HELPER_SLIPPAGE_BPS", "50");
        _expectInvalid("HELPER_* lists need one entry per helper");
        script.readEnvConfig();
        vm.setEnv("HELPER_SLIPPAGE_BPS", "50,25");
        vm.setEnv("HELPER_TELLERS", vm.toString(tellerOf[vaultA]));
        _expectInvalid("HELPER_* lists need one entry per helper");
        script.readEnvConfig();
        vm.setEnv("HELPER_TELLERS", string.concat(vm.toString(tellerOf[vaultA]), ",", vm.toString(tellerOf[vaultB])));
        vm.setEnv("HELPER_EXPECTED_ORACLES", vm.toString(address(primeOracle)));
        _expectInvalid("HELPER_* lists need one entry per helper");
        script.readEnvConfig();
    }

    // ---------------------------------------------------------------- helpers

    function _config(uint256 count) internal view returns (DeployManagedBufferHelpers.Config memory config) {
        config.deployer = deployer;
        config.pool = IManagedDirectPropAMM(address(pool));
        config.helpers = new DeployManagedBufferHelpers.HelperConfig[](count);
        for (uint256 i; i < count; ++i) {
            config.helpers[i] = _helper(vaultA, PRIME_PAIR, address(prime), 0, ID_A, 50);
        }
    }

    function _helper(address vault, uint16 pairIndex, address base, uint64 sponsorId, bytes32 customerId, uint16 bps)
        internal
        view
        returns (DeployManagedBufferHelpers.HelperConfig memory)
    {
        return DeployManagedBufferHelpers.HelperConfig({
            vault: vault,
            teller: tellerOf[vault],
            pairIndex: pairIndex,
            expectedBase: base,
            expectedQuote: address(usdc),
            expectedOracle: pairIndex == 0 ? address(usdyOracle) : address(primeOracle),
            sponsorId: sponsorId,
            customerId: customerId,
            slippageBps: bps,
            replaced: address(0)
        });
    }

    function _assertOneWarning(string memory expected) internal view {
        string[] memory warnings = script.warnings();
        assertEq(warnings.length, 1);
        assertEq(warnings[0], expected);
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _expectInvalid(string memory field) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployManagedBufferHelpers.InvalidConfig.selector, field));
    }
}
