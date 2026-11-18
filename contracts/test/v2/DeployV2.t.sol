// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Test } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { DeployV2 } from "../../script/v2/DeployV2.s.sol";
import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { Settler } from "../../src/v2/Settler.sol";
import { Venue } from "../../src/v2/Venue.sol";
import { VenueFactory } from "../../src/v2/VenueFactory.sol";
import { DeployV2Harness } from "./harness/DeployV2Harness.sol";

/// @notice Runs `DeployV2` in-process. The core calls no precompile: venues keep their access lists in their own storage.
contract DeployV2Test is Test {
    using stdJson for string;

    uint256 internal constant MAINNET = 4217;
    uint256 internal constant MODERATO = 42431;

    DeployV2Harness internal deploymentScript;
    address internal deployer = makeAddr("deployer");
    /// @dev `makeAddr`'s key for `deployer`, which `run` signs the provenance digest with.
    uint256 internal constant DEPLOYER_KEY = uint256(keccak256("deployer"));
    address internal registryAdmin = makeAddr("registryAdmin");
    /// @dev Numbers `_writeManifestAs`'s serialization keys.
    uint256 internal _manifestWrites;

    function setUp() public {
        vm.chainId(MODERATO);
        deploymentScript = new DeployV2Harness();
        deploymentScript.setInput(_config());
        assertEq(vm.addr(DEPLOYER_KEY), deployer);
        deploymentScript.setSigningKey(DEPLOYER_KEY);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deployment and wiring
    // ---------------------------------------------------------------------------------------------------------------

    function test_deploysThreeContractsWithTheFactoryAtThePredictedAddress() external {
        _useManifest("three-creates");
        vm.setNonce(deployer, 7);
        DeployV2.Deployment memory d = deploymentScript.run();

        assertEq(vm.getNonce(deployer), 10);
        assertEq(address(d.implementation), vm.computeCreateAddress(deployer, 7));
        assertEq(address(d.settler), vm.computeCreateAddress(deployer, 8));
        assertEq(address(d.factory), vm.computeCreateAddress(deployer, 9));
        assertEq(d.registry, address(0));
    }

    function test_wiresFactoryAndSettler() external {
        _useManifest("wiring");
        DeployV2.Deployment memory d = deploymentScript.run();

        assertEq(d.factory.defaultSettler(), address(d.settler));
        assertEq(d.settler.factory(), address(d.factory));
        assertEq(d.settler.implementation(), address(d.implementation));

        assertEq(d.factory.implementation(), address(d.implementation));
        assertGt(address(d.implementation).code.length, 0);
        assertEq(d.implementation.factory(), address(d.factory));
        // Nothing ever initializes the implementation.
        assertEq(d.implementation.owner(), address(0));
        assertEq(d.implementation.settler(), address(0));
    }

    function test_coreOnlyDeploysThreeCreatesAndVerifiesOnMainnet() external {
        vm.chainId(MAINNET);
        string memory path = _useManifest("core-only");
        deploymentScript.setInput(DeployV2.Config({ deployer: deployer, registryAdmin: address(0) }));
        vm.setNonce(deployer, 7);
        DeployV2.Deployment memory d = deploymentScript.run();

        assertEq(vm.getNonce(deployer), 10);
        assertEq(address(d.implementation), vm.computeCreateAddress(deployer, 7));
        assertEq(address(d.settler), vm.computeCreateAddress(deployer, 8));
        assertEq(address(d.factory), vm.computeCreateAddress(deployer, 9));
        assertEq(address(d.registry), address(0));
        assertEq(vm.computeCreateAddress(deployer, 10).code.length, 0);
        assertEq(d.implementation.owner(), address(0));
        assertEq(d.implementation.settler(), address(0));
        assertEq(d.implementation.factory(), address(d.factory));
        assertEq(d.factory.implementation(), address(d.implementation));
        assertEq(d.factory.defaultSettler(), address(d.settler));
        assertEq(d.settler.factory(), address(d.factory));
        assertEq(d.settler.implementation(), address(d.implementation));

        deploymentScript.verify();
        string memory json = vm.readFile(path);
        assertEq(json.readString(".status"), "verified");
        assertEq(json.readAddress(".contracts.registry"), address(0));
        assertEq(json.readAddress(".roles.registryAdmin"), address(0));
        assertEq(ECDSA.recover(deploymentScript.provenanceDigest(d, deployer), d.deployerSignature), deployer);

        vm.resetNonce(deployer);
        vm.setNonce(deployer, 9);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "deployer"));
        deploymentScript.verify();
    }

    function test_coreOnlyStillPinsCodeAndSignature() external {
        string memory path = _useManifest("core-only-code");
        deploymentScript.setInput(DeployV2.Config({ deployer: deployer, registryAdmin: address(0) }));
        DeployV2.Deployment memory d = deploymentScript.run();
        bytes memory factoryCode = address(d.factory).code;
        ImpostorFactory fake = new ImpostorFactory(address(d.implementation), address(d.settler));
        vm.etch(address(d.factory), address(fake).code);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "venueFactory.code"));
        deploymentScript.verify();
        vm.etch(address(d.factory), factoryCode);

        _writeAddress(path, ".roles.registryAdmin", registryAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployV2.UnexpectedDeploymentState.selector, "legacy Registry: use historical source revision"
            )
        );
        deploymentScript.verify();
        _writeAddress(path, ".roles.registryAdmin", address(0));
        vm.writeJson('"0x"', path, ".deployerSignature");
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "deployerSignature"));
        deploymentScript.verify();
        _writeSignature(path, DEPLOYER_KEY, deploymentScript.provenanceDigest(d, deployer));
        deploymentScript.verify();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Manifest
    // ---------------------------------------------------------------------------------------------------------------

    function test_writesTheManifest() external {
        string memory path = _useManifest("manifest");
        vm.roll(1234);
        uint64 nonce = vm.getNonce(deployer);
        DeployV2.Deployment memory d = deploymentScript.run();
        string memory json = vm.readFile(path);

        assertEq(json.readString(".network"), "tempo-moderato");
        assertEq(json.readUint(".chainId"), MODERATO);
        // Tests run outside `forge script --broadcast`, which a manifest calls a dry run.
        assertEq(json.readString(".status"), "dry-run");
        assertEq(json.readUint(".startBlock"), 1234);
        assertEq(json.readAddress(".deployer"), deployer);
        assertEq(json.readUint(".deployerNonce"), nonce, "the implementation's CREATE nonce");
        assertEq(d.deployerNonce, nonce);
        assertEq(json.readBytes(".deployerSignature"), d.deployerSignature);
        assertEq(json.readUint(".provenanceVersion"), deploymentScript.PROVENANCE_VERSION());
        assertEq(ECDSA.recover(deploymentScript.provenanceDigest(d, deployer), d.deployerSignature), deployer);
        assertEq(json.readAddress(".contracts.settler"), address(d.settler));
        assertEq(json.readAddress(".contracts.venueFactory"), address(d.factory));
        assertEq(json.readAddress(".contracts.venueImplementation"), address(d.implementation));
        assertEq(json.readAddress(".contracts.registry"), address(d.registry));
        assertEq(json.readAddress(".roles.registryAdmin"), address(0));
        // Exactly these keys: legacy zero fields remain for manifest compatibility; the core has no admin role.
        assertEq(vm.parseJsonKeys(json, "$").length, 11);
        assertFalse(vm.keyExistsJson(json, ".precompiles"));
        assertEq(vm.parseJsonKeys(json, ".contracts").length, 4);
        assertEq(vm.parseJsonKeys(json, ".roles").length, 1);
    }

    function test_manifestPathKeepsDryRunsApartFromBroadcasts() external view {
        assertEq(
            deploymentScript.defaultManifestPath("tempo-moderato", false), "deployments/tempo-moderato/propamm-v2.json"
        );
        assertEq(
            deploymentScript.defaultManifestPath("tempo-mainnet", true),
            "deployments/tempo-mainnet/propamm-v2.dry-run.json"
        );
    }

    function test_networkNames() external {
        assertEq(deploymentScript.networkName(MAINNET), "tempo-mainnet");
        assertEq(deploymentScript.networkName(MODERATO), "tempo-moderato");
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedChain.selector, uint256(1)));
        deploymentScript.networkName(1);
    }

    function test_verifyRewritesTheManifestFromLiveState() external {
        string memory path = _useManifest("verify");
        vm.roll(99);
        DeployV2.Deployment memory d = deploymentScript.run();
        assertEq(vm.readFile(path).readString(".status"), "dry-run");

        vm.roll(500);
        DeployV2.Deployment memory verified = deploymentScript.verify();
        assertEq(address(verified.implementation), address(d.implementation));
        assertEq(address(verified.settler), address(d.settler));
        assertEq(address(verified.registry), address(d.registry));

        string memory json = vm.readFile(path);
        assertEq(json.readString(".status"), "verified");
        // The start block stays the one recorded at deployment.
        assertEq(json.readUint(".startBlock"), 99);
        assertEq(json.readAddress(".contracts.venueFactory"), address(d.factory));
        assertEq(json.readAddress(".roles.registryAdmin"), address(0));
    }

    function test_verifyRejectsAFutureStartBlockWithoutRewritingManifest() external {
        string memory path = _useManifest("verify-future-start-block");
        vm.roll(500);
        deploymentScript.run();
        vm.writeJson("501", path, ".startBlock");
        string memory before = vm.readFile(path);

        vm.expectRevert(
            abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "startBlock exceeds current block")
        );
        deploymentScript.verify();
        assertEq(vm.readFile(path), before, "refusal must leave the manifest unchanged");
    }

    function test_verifyPreservesBoundedUnsignedStartBlockWithoutResigning() external {
        string memory path = _useManifest("verify-unsigned-start-block");
        vm.roll(500);
        DeployV2.Deployment memory d = deploymentScript.run();
        bytes32 digest = deploymentScript.provenanceDigest(d, deployer);
        bytes memory signature = d.deployerSignature;

        // These are indexing hints, not claims of the actual creation block.
        vm.writeJson("0", path, ".startBlock");
        deploymentScript.verify();
        assertEq(vm.readFile(path).readUint(".startBlock"), 0);
        vm.writeJson("500", path, ".startBlock");
        DeployV2.Deployment memory verified = deploymentScript.verify();
        assertEq(vm.readFile(path).readUint(".startBlock"), 500);
        assertEq(deploymentScript.provenanceDigest(verified, deployer), digest);
        assertEq(verified.deployerSignature, signature);
    }

    function test_verifyRejectsAManifestThatDoesNotMatchTheChain() external {
        string memory path = _useManifest("verify-mismatch");
        deploymentScript.run();

        vm.writeJson(string.concat('"', vm.toString(makeAddr("nothing")), '"'), path, ".contracts.registry");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployV2.UnexpectedDeploymentState.selector, "legacy Registry: use historical source revision"
            )
        );
        deploymentScript.verify();

        deploymentScript.run();
        vm.writeJson(string.concat('"', vm.toString(makeAddr("someoneElse")), '"'), path, ".roles.registryAdmin");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployV2.UnexpectedDeploymentState.selector, "legacy Registry: use historical source revision"
            )
        );
        deploymentScript.verify();

        deploymentScript.run();
        vm.writeJson(string.concat('"', vm.toString(makeAddr("nothing")), '"'), path, ".contracts.venueImplementation");
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "venueImplementation"));
        deploymentScript.verify();

        deploymentScript.run();
        vm.chainId(MAINNET);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedChain.selector, MODERATO));
        deploymentScript.verify();
    }

    /// @dev `verify` rebuilds the `Venue` implementation, the `Settler`, the `VenueFactory` from
    /// source and compares their code: code that answers every wiring view correctly but isn't this source fails, even
    /// at the right address under the deployer's signature. The factory matters most: it alone deploys and initializes
    /// venues, and the Settler fills whatever it deploys.
    function test_verifyRejectsCodeThatIsNotThisSource() external {
        _useManifest("verify-code");
        DeployV2.Deployment memory d = deploymentScript.run();
        bytes memory venueCode = address(d.implementation).code;
        ImpostorImplementation fakeVenue = new ImpostorImplementation(address(d.factory));
        vm.etch(address(d.implementation), address(fakeVenue).code);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "venueImplementation.code"));
        deploymentScript.verify();
        vm.etch(address(d.implementation), venueCode);
        deploymentScript.verify();

        bytes memory settlerCode = address(d.settler).code;
        ImpostorSettler fakeSettler = new ImpostorSettler(address(d.factory), address(d.implementation));
        vm.etch(address(d.settler), address(fakeSettler).code);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "settler.code"));
        deploymentScript.verify();
        vm.etch(address(d.settler), settlerCode);
        deploymentScript.verify();

        // A factory that answers every view but can also initialize any clone, with any settler.
        ImpostorFactory fakeFactory = new ImpostorFactory(address(d.implementation), address(d.settler));
        vm.etch(address(d.factory), address(fakeFactory).code);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "venueFactory.code"));
        deploymentScript.verify();
    }

    /// @dev Every field of the deployment the deployer signs changes the digest, the Registry's address included.
    function test_provenanceDigestBindsEveryContract() external {
        DeployV2.Deployment memory d = DeployV2.Deployment({
            deployerNonce: 3,
            implementation: Venue(makeAddr("implementation")),
            settler: Settler(makeAddr("settler")),
            factory: VenueFactory(makeAddr("factory")),
            registry: address(0),
            deployerSignature: "",
            registryCreationTx: bytes32(0)
        });
        bytes32 digest = deploymentScript.provenanceDigest(d, deployer);
        assertNotEq(deploymentScript.provenanceDigest(d, makeAddr("otherDeployer")), digest, "deployer");

        d.registry = makeAddr("otherRegistry");
        assertNotEq(deploymentScript.provenanceDigest(d, deployer), digest, "registry");
        d.registry = address(0);
        assertEq(deploymentScript.provenanceDigest(d, deployer), digest);

        d.factory = VenueFactory(makeAddr("otherFactory"));
        assertNotEq(deploymentScript.provenanceDigest(d, deployer), digest, "factory");
        d.factory = VenueFactory(makeAddr("factory"));
        d.settler = Settler(makeAddr("otherSettler"));
        assertNotEq(deploymentScript.provenanceDigest(d, deployer), digest, "settler");
        d.settler = Settler(makeAddr("settler"));
        d.implementation = Venue(makeAddr("otherImplementation"));
        assertNotEq(deploymentScript.provenanceDigest(d, deployer), digest, "implementation");
        d.implementation = Venue(makeAddr("implementation"));
        d.deployerNonce = 4;
        assertNotEq(deploymentScript.provenanceDigest(d, deployer), digest, "deployerNonce");
        d.deployerNonce = 3;
        vm.chainId(MAINNET);
        assertNotEq(deploymentScript.provenanceDigest(d, deployer), digest, "chain");
    }

    /// @dev The exact preimage, for anyone who computes the digest off chain. Version 2 adds the version and the
    /// Registry to version 1's fields.
    function test_provenanceDigestIsVersion2() external {
        DeployV2.Deployment memory d = DeployV2.Deployment({
            deployerNonce: 3,
            implementation: Venue(makeAddr("implementation")),
            settler: Settler(makeAddr("settler")),
            factory: VenueFactory(makeAddr("factory")),
            registry: address(0),
            deployerSignature: "",
            registryCreationTx: bytes32(0)
        });
        assertEq(deploymentScript.PROVENANCE_VERSION(), 2);
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("propAMM v2 DeployV2 provenance"),
                uint256(2),
                MODERATO,
                deployer,
                uint256(3),
                makeAddr("implementation"),
                makeAddr("settler"),
                makeAddr("factory"),
                address(0)
            )
        );
        assertEq(deploymentScript.provenanceDigest(d, deployer), expected);
        assertNotEq(_v1Digest(d), expected);
    }

    /// @dev The immutable historical mainnet record must keep verifying under the unchanged version-2 digest.
    /// No RPC or manifest write: this pins compatibility with the original deployer's signature.
    function test_historicalMainnetManifestSignatureIsUnchanged() external {
        string memory json = vm.readFile("deployments/tempo-mainnet/propamm-v2.json");
        vm.chainId(json.readUint(".chainId"));
        DeployV2.Deployment memory d = DeployV2.Deployment({
            deployerNonce: json.readUint(".deployerNonce"),
            implementation: Venue(json.readAddress(".contracts.venueImplementation")),
            settler: Settler(json.readAddress(".contracts.settler")),
            factory: VenueFactory(json.readAddress(".contracts.venueFactory")),
            registry: json.readAddress(".contracts.registry"),
            deployerSignature: json.readBytes(".deployerSignature"),
            registryCreationTx: json.readBytes32Or(".registryCreationTx", bytes32(0))
        });
        address signer = json.readAddress(".deployer");
        assertEq(json.readUint(".provenanceVersion"), 2);
        assertEq(d.registry, address(0));
        assertEq(json.readAddress(".roles.registryAdmin"), address(0));
        assertEq(d.registryCreationTx, bytes32(0));
        assertEq(ECDSA.recover(deploymentScript.provenanceDigest(d, signer), d.deployerSignature), signer);
    }

    /// @dev Version 1 of `provenanceDigest` left out the Registry, and its manifests have no `provenanceVersion`.
    /// `verify` refuses one with the version-2 digest for the deployer to sign, and accepts the manifest re-signed.
    function test_verifyAsksToReSignAVersion1Manifest() external {
        string memory path = _useManifest("verify-v1");
        DeployV2.Deployment memory d = deploymentScript.run();
        bytes32 digest = deploymentScript.provenanceDigest(d, deployer);
        bytes memory v1Signature = _sign(DEPLOYER_KEY, _v1Digest(d));
        bytes memory resign = abi.encodeWithSelector(DeployV2.ResignProvenance.selector, uint256(1), uint256(2), digest);

        // What the previous `DeployV2` wrote: no `provenanceVersion`, and the deployer's version-1 signature.
        _writeManifestAs(path, d, 0, v1Signature);
        vm.expectRevert(resign);
        deploymentScript.verify();
        assertFalse(vm.keyExistsJson(vm.readFile(path), ".provenanceVersion"), "nothing is rewritten");
        _writeManifestAs(path, d, 1, v1Signature);
        vm.expectRevert(resign);
        deploymentScript.verify();

        // Relabelling isn't re-signing: version 2 needs the deployer's signature of the version-2 digest.
        _writeManifestAs(path, d, 2, v1Signature);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "deployerSignature"));
        deploymentScript.verify();
        // A version this script doesn't know.
        _writeManifestAs(path, d, 3, _sign(DEPLOYER_KEY, digest));
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "provenanceVersion"));
        deploymentScript.verify();

        // Re-signed as the error says, it verifies, and the rewritten manifest records version 2.
        _writeManifestAs(path, d, 2, _sign(DEPLOYER_KEY, digest));
        deploymentScript.verify();
        string memory json = vm.readFile(path);
        assertEq(json.readString(".status"), "verified");
        assertEq(json.readUint(".provenanceVersion"), 2);
        assertEq(json.readBytes(".deployerSignature"), _sign(DEPLOYER_KEY, digest));
    }

    /// @dev Code shows what an address runs now, not what ran there before: an address that can be occupied twice could
    /// first hold code that initializes a venue with a settler of its choosing and self-destructs, and then the real
    /// factory. So the core must be the deployer's three consecutive CREATEs from the recorded nonce, signed by the
    /// deployer: only an externally owned account signs, and its nonce never goes back. A contract deployer, even one
    /// that leaves no code and a high nonce, could have been destroyed and created again with its nonce reset.
    function test_verifyRequiresTheCoreAtTheDeployersCreateAddresses() external {
        string memory path = _useManifest("verify-provenance");
        uint64 nonce = vm.getNonce(deployer);
        DeployV2.Deployment memory d = deploymentScript.run();
        bytes memory moved = abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "deployerNonce");

        // Another nonce, or another deployer, names addresses the core doesn't sit at.
        vm.writeJson(vm.toString(uint256(nonce) + 1), path, ".deployerNonce");
        vm.expectRevert(moved);
        deploymentScript.verify();
        vm.writeJson(vm.toString(uint256(nonce)), path, ".deployerNonce");
        vm.writeJson(string.concat('"', vm.toString(makeAddr("otherDeployer")), '"'), path, ".deployer");
        vm.expectRevert(moved);
        deploymentScript.verify();
        vm.writeJson(string.concat('"', vm.toString(deployer), '"'), path, ".deployer");
        deploymentScript.verify();

        bytes memory unsigned = abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "deployerSignature");
        // No signature, as from a dry run without the deployer's wallet.
        vm.writeJson('"0x"', path, ".deployerSignature");
        vm.expectRevert(unsigned);
        deploymentScript.verify();
        // Another key's signature: a contract deployer has no key of its own.
        (, uint256 otherKey) = makeAddrAndKey("other");
        _writeSignature(path, otherKey, deploymentScript.provenanceDigest(d, deployer));
        vm.expectRevert(unsigned);
        deploymentScript.verify();
        // The deployer's signature of other addresses.
        DeployV2.Deployment memory other = DeployV2.Deployment({
            deployerNonce: d.deployerNonce,
            implementation: d.implementation,
            settler: d.settler,
            factory: VenueFactory(makeAddr("otherFactory")),
            registry: d.registry,
            deployerSignature: "",
            registryCreationTx: bytes32(0)
        });
        _writeSignature(path, DEPLOYER_KEY, deploymentScript.provenanceDigest(other, deployer));
        vm.expectRevert(unsigned);
        deploymentScript.verify();

        // The deployer's own signature verifies, with or without an EIP-7702 delegation.
        _writeSignature(path, DEPLOYER_KEY, deploymentScript.provenanceDigest(d, deployer));
        deploymentScript.verify();
        vm.etch(deployer, abi.encodePacked(hex"ef0100", makeAddr("delegate")));
        deploymentScript.verify();
        // A nonce at or below the factory's can't have made the core's three CREATEs.
        vm.etch(deployer, "");
        vm.resetNonce(deployer);
        vm.setNonce(deployer, nonce + 2);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedDeploymentState.selector, "deployer"));
        deploymentScript.verify();
    }

    /// @dev The comparison leaves out each contract's CBOR metadata trailer, which hashes the source text and the
    /// remappings: a deployment built from a checkout whose comments or submodules differ still verifies, and the
    /// rebuild leaves the deployed code in place.
    function test_verifyIgnoresOnlyTheMetadataTrailer() external {
        _useManifest("verify-metadata");
        DeployV2.Deployment memory d = deploymentScript.run();
        address[3] memory pinned = [address(d.implementation), address(d.settler), address(d.factory)];
        bytes[3] memory altered;
        for (uint256 i; i < pinned.length; ++i) {
            altered[i] = pinned[i].code;
            // A byte of the metadata hash: the trailer is `a2 64 'ipfs' 58 22 <34 bytes> 64 'solc' 43 <3 bytes> 0033`.
            uint256 at = altered[i].length - 20;
            altered[i][at] = ~altered[i][at];
            vm.etch(pinned[i], altered[i]);
        }
        deploymentScript.verify();
        for (uint256 i; i < pinned.length; ++i) {
            assertEq(pinned[i].code, altered[i], "the deployed code stays in place");
        }
    }

    function test_sameExecutableCode() external view {
        // Five executable bytes, then a four-byte trailer and its length.
        bytes memory code = bytes.concat(hex"60806040", hex"fe", hex"a2646970", hex"0004");
        bytes memory otherTrailer = bytes.concat(hex"60806040", hex"fe", hex"ffffffff", hex"0004");
        bytes memory otherByte = bytes.concat(hex"60806041", hex"fe", hex"a2646970", hex"0004");
        assertTrue(deploymentScript.sameExecutableCode(code, code));
        assertTrue(deploymentScript.sameExecutableCode(otherTrailer, code));
        assertFalse(deploymentScript.sameExecutableCode(otherByte, code));
        assertFalse(deploymentScript.sameExecutableCode(bytes.concat(code, hex"00"), code), "another length");
        assertFalse(deploymentScript.sameExecutableCode(hex"00", hex"00"), "too short for a trailer");
        assertFalse(deploymentScript.sameExecutableCode(hex"00ff", hex"00ff"), "a trailer longer than the code");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fail-closed inputs
    // ---------------------------------------------------------------------------------------------------------------

    function test_rejectsUnsupportedChain() external {
        _useManifest("wrong-chain");
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.UnexpectedChain.selector, uint256(1)));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), 0);
    }

    function test_rejectsZeroOrDefaultSender() external {
        _useManifest("zero-roles");
        DeployV2.Config memory config = _config();
        config.deployer = address(0);
        _reject(config, "sender");
        config.deployer = DEFAULT_SENDER;
        _reject(config, "sender");
    }

    /// @dev The only test that reads the process environment; no other test touches these names. Forge can't
    /// broadcast under a prank, so the sender, and with it the deployer, is this test contract.
    function test_readsExplicitEnvironmentInputs() external {
        _useManifest("env");
        deploymentScript.setUseEnv(true);
        vm.setEnv("REGISTRY_ADMIN", vm.toString(registryAdmin));

        vm.expectRevert(
            abi.encodeWithSelector(DeployV2.InvalidConfig.selector, "REGISTRY_ADMIN retired; leave unset or zero")
        );
        deploymentScript.run();

        // Zero or empty selects the three-contract core; a malformed nonempty value still fails.
        vm.setEnv("REGISTRY_ADMIN", vm.toString(address(0)));
        assertEq(address(deploymentScript.run().registry), address(0));
        vm.setEnv("REGISTRY_ADMIN", "");
        assertEq(address(deploymentScript.run().registry), address(0));
        vm.setEnv("REGISTRY_ADMIN", "not-an-address");
        vm.expectRevert();
        deploymentScript.run();
        vm.setEnv("REGISTRY_ADMIN", "");
    }

    function test_rejectsRetiredRegistryConfigOnBothChains() external {
        _useManifest("retired-config");
        DeployV2.Config memory config = _config();
        config.registryAdmin = registryAdmin;
        _reject(config, "REGISTRY_ADMIN retired; leave unset or zero");
        vm.chainId(MAINNET);
        _reject(config, "REGISTRY_ADMIN retired; leave unset or zero");
    }

    function test_rejectsLegacyRegistryManifestEvenWithValidSignature() external {
        string memory path = _useManifest("retired-manifest");
        DeployV2.Deployment memory d = deploymentScript.run();
        d.registry = makeAddr("legacyRegistry");
        _writeAddress(path, ".contracts.registry", d.registry);
        _writeSignature(path, DEPLOYER_KEY, deploymentScript.provenanceDigest(d, deployer));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployV2.UnexpectedDeploymentState.selector, "legacy Registry: use historical source revision"
            )
        );
        deploymentScript.verify();
        assertEq(vm.readFile(path).readString(".status"), "dry-run");
    }

    function test_rejectsNonzeroLegacyCreationEvidence() external {
        string memory path = _useManifest("retired-evidence");
        deploymentScript.run();
        vm.writeJson(string.concat('"', vm.toString(bytes32(uint256(1))), '"'), path, ".registryCreationTx");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployV2.UnexpectedDeploymentState.selector, "legacy Registry: use historical source revision"
            )
        );
        deploymentScript.verify();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _config() internal view returns (DeployV2.Config memory) {
        return DeployV2.Config({ deployer: deployer, registryAdmin: address(0) });
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Version 1 of `provenanceDigest`, which the previous `DeployV2` signed: no version and no Registry.
    function _v1Digest(DeployV2.Deployment memory d) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("propAMM v2 DeployV2 provenance"),
                block.chainid,
                deployer,
                d.deployerNonce,
                address(d.implementation),
                address(d.settler),
                address(d.factory)
            )
        );
    }

    /// @dev Writes a verified manifest for `d` with `signature`, and `provenanceVersion` set to `version`, or left out
    /// when `version` is 0, as version 1 did. Fresh serialization keys on every call, so no field carries over.
    function _writeManifestAs(string memory path, DeployV2.Deployment memory d, uint256 version, bytes memory signature)
        internal
    {
        string memory id = string.concat(path, "#", vm.toString(++_manifestWrites));
        // Each serialize call returns its object so far; only the last call's result is used.
        // forge-lint: disable-start(unused-return)
        string memory contractsKey = string.concat(id, ".contracts");
        vm.serializeAddress(contractsKey, "settler", address(d.settler));
        vm.serializeAddress(contractsKey, "venueFactory", address(d.factory));
        vm.serializeAddress(contractsKey, "venueImplementation", address(d.implementation));
        string memory contracts = vm.serializeAddress(contractsKey, "registry", address(d.registry));
        string memory roles = vm.serializeAddress(string.concat(id, ".roles"), "registryAdmin", address(0));
        vm.serializeString(id, "network", "tempo-moderato");
        vm.serializeUint(id, "chainId", MODERATO);
        vm.serializeString(id, "status", "verified");
        vm.serializeUint(id, "startBlock", 1);
        vm.serializeAddress(id, "deployer", deployer);
        vm.serializeUint(id, "deployerNonce", d.deployerNonce);
        vm.serializeBytes(id, "deployerSignature", signature);
        if (version != 0) vm.serializeUint(id, "provenanceVersion", version);
        vm.serializeString(id, "contracts", contracts);
        string memory json = vm.serializeString(id, "roles", roles);
        // forge-lint: disable-end(unused-return)
        vm.writeJson(json, path);
    }

    function _writeAddress(string memory path, string memory key, address value) internal {
        vm.writeJson(string.concat('"', vm.toString(value), '"'), path, key);
    }

    function _writeSignature(string memory path, uint256 key, bytes32 digest) internal {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        vm.writeJson(string.concat('"', vm.toString(abi.encodePacked(r, s, v)), '"'), path, ".deployerSignature");
    }

    function _useManifest(string memory name) internal returns (string memory path) {
        // Relative to the project root, like the script's own path, so the gas snapshot doesn't depend on where the
        // repository is checked out.
        path = string.concat("cache/propamm-v2-deploy-test/", name, ".json");
        deploymentScript.setManifestFile(path);
    }

    function _reject(DeployV2.Config memory config, string memory reason) internal {
        deploymentScript.setInput(config);
        uint64 nonce = vm.getNonce(deployer);
        vm.expectRevert(abi.encodeWithSelector(DeployV2.InvalidConfig.selector, reason));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), nonce);
    }
}

/// @dev Answers every view `DeployV2` checks on the `Venue` implementation, with other code.
contract ImpostorImplementation {
    address internal immutable FACTORY;

    constructor(address factory_) {
        FACTORY = factory_;
    }

    function factory() external view returns (address) {
        return FACTORY;
    }

    function owner() external pure returns (address) { }

    function settler() external pure returns (address) { }
}

/// @dev Answers every view `DeployV2` checks on the `Settler`, with other code.
contract ImpostorSettler {
    address internal immutable FACTORY;
    address internal immutable IMPLEMENTATION;

    constructor(address factory_, address implementation_) {
        FACTORY = factory_;
        IMPLEMENTATION = implementation_;
    }

    function factory() external view returns (address) {
        return FACTORY;
    }

    function implementation() external view returns (address) {
        return IMPLEMENTATION;
    }
}

/// @dev Answers every view `DeployV2` checks on the `VenueFactory`, and can also initialize any clone of the
/// implementation with any owner and settler, which the real factory never does.
contract ImpostorFactory {
    address internal immutable IMPLEMENTATION;
    address internal immutable DEFAULT_SETTLER;

    constructor(address implementation_, address defaultSettler_) {
        IMPLEMENTATION = implementation_;
        DEFAULT_SETTLER = defaultSettler_;
    }

    function implementation() external view returns (address) {
        return IMPLEMENTATION;
    }

    function defaultSettler() external view returns (address) {
        return DEFAULT_SETTLER;
    }

    function initializeAny(IVenue venue, address owner, address settler) external {
        venue.initialize(owner, settler);
    }
}
