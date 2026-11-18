// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Script, console2 } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { VmSafe } from "forge-std/Vm.sol";

import { Settler } from "../../src/v2/Settler.sol";
import { Venue } from "../../src/v2/Venue.sol";
import { VenueFactory } from "../../src/v2/VenueFactory.sol";

/// @notice Deploys the propAMM v2 core on Tempo mainnet or Moderato: the `Venue` implementation, `Settler`,
/// `VenueFactory`. The retired Registry is not deployed.
/// @dev Three transactions, from the sender (`--sender`, or the only signer), in this order:
/// 1. `Venue(predictedFactory)`, the implementation, where the factory address is predicted from the deployer's
///    nonce two transactions on. It is the largest deployment (`docs/v2-deployment.md` keeps the measured gas, and
///    `test/fork/VenueAccessGas.t.sol` holds it under the 30M transaction cap), so it gets a transaction of its own
///    and the factory's carries none of its code;
/// 2. `Settler(implementation)`, which fills only the venues the implementation's factory creates;
/// 3. `VenueFactory(implementation, settler)`, which must land at the prediction: its constructor rejects an
///    implementation that names another factory;
/// Broadcast on the protocol nonce only (no `--tempo.nonce-key`, `--tempo.lane`, `--tempo.expires` or `--batch`), so
/// the transactions are the deployer's consecutive CREATEs, in order: the factory lands at its predicted
/// address, and `verify` can prove each deployment from `deployerNonce`.
///
/// `run` and `verify` pin the code of every deployed contract: the three that decide which venues exist and which fill, the
/// `Venue` implementation, the `Settler` and the `VenueFactory`, the only account that deploys and initializes venues,
/// each rebuilt from this source in the simulation,
/// at its own address and from its constructor arguments, and its executable code must equal the deployed code byte
/// for byte, immutables included. The comparison leaves out the CBOR metadata trailer, which hashes every source
/// file's text and the remappings, so a comment edit or another submodule checkout doesn't fail a correct deployment.
///
/// Code shows what an address runs now, not what ran there before. `Venue.initialize` refuses a factory without code,
/// so the factory's constructor can't initialize a venue; but an address that can be occupied twice could first hold
/// other code that initializes a venue with a settler of its choosing and self-destructs in the same transaction, and
/// then the real factory. So `verify` also requires the contracts to be the deployer's consecutive CREATEs
/// from the recorded `deployerNonce` (`_checkCreates`), and the deployer's signature of `provenanceDigest`, which
/// binds all four address fields, including zero for an omitted Registry (`_checkProvenance`). Only an externally
/// owned account can sign, and its nonce never goes back, so each address has had only one occupant. This does not
/// prove what its constructor did. Nonzero legacy Registry manifests are rejected; verify those with their
/// historical source revision, not this core-only script.
/// `run` deploys them that way itself,
/// from the broadcasting account, and signs with its wallet (`--account` or `--private-key`). With no wallet for the
/// deployer, as in a dry run, the manifest's `deployerSignature` is empty: sign the logged digest with
/// `cast wallet sign --no-hash` and put the signature in the manifest before running `verify`.
///
/// The manifest records which `provenanceDigest` its signature is for (`provenanceVersion`). Version 1 left out the
/// Registry, and its manifests have no `provenanceVersion`. `verify` refuses an older version with `ResignProvenance`
/// once every other check has passed, and gives the current digest for the deployer to sign.
///
/// Forge only sends transactions with `--broadcast`. `run` writes `deployments/<network>/propamm-v2.json` on a
/// broadcast and `propamm-v2.dry-run.json` on a simulation. Run `verify` after the broadcast to re-check the wiring on
/// chain and rewrite the manifest from live state.
contract DeployV2 is Script {
    using stdJson for string;

    error UnexpectedChain(uint256 chainId);
    error InvalidConfig(string field);
    error FactoryAddressMismatch(address predicted, address deployed);
    error UnexpectedDeploymentState(string field);
    /// @notice The manifest's `deployerSignature` is for an older `provenanceDigest`. Sign `digest`, the current one,
    /// with the deployer's key (`cast wallet sign --no-hash`), put the signature in `deployerSignature`, set
    /// `provenanceVersion` to `requiredVersion` and run `verify` again. Raised only after every other check passed.
    error ResignProvenance(uint256 manifestVersion, uint256 requiredVersion, bytes32 digest);

    /// @notice The `provenanceDigest` version `run` signs and `verify` accepts. Version 2 binds the Registry too.
    uint256 public constant PROVENANCE_VERSION = 2;

    uint256 internal constant TEMPO_MAINNET_CHAIN_ID = 4217;
    uint256 internal constant TEMPO_MODERATO_CHAIN_ID = 42431;

    struct Config {
        address deployer;
        /// @dev Legacy configuration field: only zero is accepted.
        address registryAdmin;
    }

    struct Deployment {
        /// @dev The deployer's nonce for the implementation's CREATE; the Settler and factory take the next two,
        /// with no fourth deployment.
        uint256 deployerNonce;
        Venue implementation;
        Settler settler;
        VenueFactory factory;
        /// @dev Legacy version-2 digest and manifest field: must remain zero.
        address registry;
        /// @dev The deployer's 65-byte signature of `provenanceDigest`, or empty when `run` had no wallet for it.
        bytes deployerSignature;
        /// @dev Legacy manifest field: only zero is accepted.
        bytes32 registryCreationTx;
    }

    /// @notice Deploys, checks the wiring, logs every address and writes the manifest.
    /// @dev Public, like `verify`, so `test/v2/script/DeployV2RunVerify.s.sol` can run both in one Forge script
    /// simulation, which is how CI holds them to Forge's script rules (no `address(this)` in a script contract).
    function run() public returns (Deployment memory deployed) {
        string memory network = networkName(block.chainid);
        Config memory config = _readConfig();
        _preflight(config);

        console2.log("Network", network);
        console2.log("Deployer", config.deployer);

        uint256 startBlock = block.number;
        // The implementation takes the factory's address, the Settler the implementation's, and the factory both. The
        // factory is the deployer's third CREATE from here, so its address is known before any of them exists.
        deployed.deployerNonce = vm.getNonce(config.deployer);
        address predictedFactory = vm.computeCreateAddress(config.deployer, deployed.deployerNonce + 2);

        // The explicit sender must be the checked deployer, even if Forge has other signers available.
        vm.startBroadcast(config.deployer);
        deployed.implementation = new Venue(predictedFactory);
        deployed.settler = new Settler(deployed.implementation);
        deployed.factory = new VenueFactory(deployed.implementation, address(deployed.settler));
        if (address(deployed.factory) != predictedFactory) {
            revert FactoryAddressMismatch(predictedFactory, address(deployed.factory));
        }
        vm.stopBroadcast();

        _checkDeployment(deployed, config);
        _logDeployment(deployed);
        deployed.deployerSignature = _signProvenance(config.deployer, provenanceDigest(deployed, config.deployer));

        bool broadcast =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        _writeManifest(
            network,
            config,
            deployed,
            broadcast ? "broadcast" : "dry-run",
            startBlock,
            _manifestPath(network, !broadcast)
        );
    }

    /// @notice Re-checks the deployment in `deployments/<network>/propamm-v2.json` against live chain state and
    /// rewrites that manifest from it with status `verified`. Needs no signer and sends nothing; run it after the
    /// broadcast, before any admin role moves. `startBlock` remains unsigned indexing metadata, not a verified creation block.
    function verify() public returns (Deployment memory deployed) {
        string memory network = networkName(block.chainid);
        string memory path = _manifestPath(network, false);
        string memory json = vm.readFile(path);
        if (json.readUint(".chainId") != block.chainid) revert UnexpectedChain(json.readUint(".chainId"));
        uint256 startBlock = json.readUint(".startBlock");
        if (startBlock > block.number) revert UnexpectedDeploymentState("startBlock exceeds current block");

        Config memory config = Config({
            deployer: json.readAddress(".deployer"), registryAdmin: json.readAddress(".roles.registryAdmin")
        });
        deployed.deployerNonce = json.readUint(".deployerNonce");
        deployed.implementation = Venue(json.readAddress(".contracts.venueImplementation"));
        deployed.settler = Settler(json.readAddress(".contracts.settler"));
        deployed.factory = VenueFactory(json.readAddress(".contracts.venueFactory"));
        deployed.registry = json.readAddress(".contracts.registry");
        deployed.deployerSignature = json.readBytes(".deployerSignature");
        deployed.registryCreationTx = json.readBytes32Or(".registryCreationTx", bytes32(0));
        _checkLegacyFields(deployed, config);
        // Version 1 manifests have no `provenanceVersion`.
        uint256 version = json.readUintOr(".provenanceVersion", 1);
        _requireCode(address(deployed.implementation), "venueImplementation");
        _requireCode(address(deployed.settler), "settler");
        _requireCode(address(deployed.factory), "venueFactory");

        // The signature last, so `ResignProvenance` only offers the digest of a deployment every other check passed.
        _checkCreates(deployed, config.deployer);
        _checkDeployment(deployed, config);
        _checkProvenance(deployed, config.deployer, version);
        _logDeployment(deployed);
        console2.log("startBlock is unsigned: confirm it against creation receipts before indexing");
        _writeManifest(network, config, deployed, "verified", startBlock, path);
    }

    /// @notice The manifest directory name for a supported chain. Reverts on any other chain.
    function networkName(uint256 chainId) public pure returns (string memory) {
        if (chainId == TEMPO_MAINNET_CHAIN_ID) return "tempo-mainnet";
        if (chainId == TEMPO_MODERATO_CHAIN_ID) return "tempo-moderato";
        revert UnexpectedChain(chainId);
    }

    /// @dev The deployer is the script's sender, which is also the broadcaster. Test harnesses override this to avoid
    /// process-global environment races between parallel tests.
    function _readConfig() internal view virtual returns (Config memory) {
        // Read as text first: envOr(address) also defaults on malformed input, silently omitting an intended Registry.
        string memory admin = vm.envOr("REGISTRY_ADMIN", string(""));
        return
            Config({
                deployer: msg.sender, registryAdmin: bytes(admin).length == 0 ? address(0) : vm.parseAddress(admin)
            });
    }

    /// @dev `deployments/<network>/propamm-v2.json`, or `propamm-v2.dry-run.json` for a simulation, so a dry run never
    /// overwrites the record of a broadcast. Relative to the project root, which Forge's file cheatcodes resolve it
    /// against, so the path and its cost don't depend on where the repository is checked out. Test harnesses override
    /// this.
    function _manifestPath(string memory network, bool dryRun) internal view virtual returns (string memory) {
        return string.concat("deployments/", network, "/propamm-v2", dryRun ? ".dry-run" : "", ".json");
    }

    function _preflight(Config memory config) internal view {
        // Forge's default sender has no signer, so a run from it can't be the reviewed deployer.
        if (config.deployer == address(0) || config.deployer == DEFAULT_SENDER) revert InvalidConfig("sender");
        if (config.registryAdmin != address(0)) revert InvalidConfig("REGISTRY_ADMIN retired; leave unset or zero");
    }

    /// @dev Preserve the signed version-2 zero fields without accepting retired Registry deployments.
    function _checkLegacyFields(Deployment memory d, Config memory config) internal pure {
        if (d.registry != address(0) || config.registryAdmin != address(0) || d.registryCreationTx != bytes32(0)) {
            revert UnexpectedDeploymentState("legacy Registry: use historical source revision");
        }
    }

    /// @dev Not a view: it rebuilds the implementation, the Settler and the factory in the simulation,
    /// after the broadcast, to compare their code. Nothing it runs is broadcast.
    function _checkDeployment(Deployment memory d, Config memory config) internal {
        _checkLegacyFields(d, config);
        address factory = address(d.factory);
        address implementation = address(d.implementation);
        if (d.factory.implementation() != implementation) revert UnexpectedDeploymentState("factory.implementation");
        if (d.factory.defaultSettler() != address(d.settler)) {
            revert UnexpectedDeploymentState("factory.defaultSettler");
        }

        if (
            d.implementation.factory() != factory || d.implementation.owner() != address(0)
                || d.implementation.settler() != address(0)
        ) revert UnexpectedDeploymentState("venueImplementation");
        if (d.settler.factory() != factory) revert UnexpectedDeploymentState("settler.factory");
        if (d.settler.implementation() != implementation) revert UnexpectedDeploymentState("settler.implementation");

        // In dependency order: the factory's constructor reads the implementation.
        _requireSourceCode(
            implementation, bytes.concat(type(Venue).creationCode, abi.encode(factory)), "venueImplementation.code"
        );
        _requireSourceCode(
            address(d.settler), bytes.concat(type(Settler).creationCode, abi.encode(implementation)), "settler.code"
        );
        _requireSourceCode(
            factory,
            bytes.concat(type(VenueFactory).creationCode, abi.encode(implementation, address(d.settler))),
            "venueFactory.code"
        );
    }

    /// @notice What the deployer signs, `provenanceDigest` version `PROVENANCE_VERSION`: the version, the chain, the
    /// deployer, its nonce for the implementation's CREATE, and the implementation, the Settler, the factory and the
    /// Registry (zero when omitted). Version 1 bound neither the version nor the Registry.
    function provenanceDigest(Deployment memory d, address deployer) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("propAMM v2 DeployV2 provenance"),
                PROVENANCE_VERSION,
                block.chainid,
                deployer,
                d.deployerNonce,
                address(d.implementation),
                address(d.settler),
                address(d.factory),
                address(d.registry)
            )
        );
    }

    /// @dev Requires the three core contracts to sit at the deployer's consecutive CREATE addresses, and a
    /// live nonce past the last deployed contract's. The signed zero Registry field binds its omission too.
    function _checkCreates(Deployment memory d, address deployer) internal view {
        uint256 nonce = d.deployerNonce;
        if (
            address(d.implementation) != vm.computeCreateAddress(deployer, nonce)
                || address(d.settler) != vm.computeCreateAddress(deployer, nonce + 1)
                || address(d.factory) != vm.computeCreateAddress(deployer, nonce + 2)
        ) revert UnexpectedDeploymentState("deployerNonce");
        uint256 lastNonce = nonce + 2;
        if (vm.getNonce(deployer) <= lastNonce) revert UnexpectedDeploymentState("deployer");
    }

    /// @dev Requires the deployer's signature of the current `provenanceDigest`. Neither code nor nonce shows that an
    /// account's nonce never went back: a contract could be destroyed in its creation transaction and created again,
    /// nonce reset, by init code that bumps the nonce and leaves no code. A signature does: only an externally owned
    /// account (with or without an EIP-7702 delegation) signs, and its nonce never resets. Each address `_checkCreates`
    /// pinned has then only ever held one contract, the one whose code the source checks compare. A manifest signed
    /// for an older version gets `ResignProvenance`, with the digest to sign.
    function _checkProvenance(Deployment memory d, address deployer, uint256 version) internal view {
        bytes32 digest = provenanceDigest(d, deployer);
        if (version < PROVENANCE_VERSION) {
            console2.log("deployerSignature signs provenance version", version);
            console2.log("verify requires provenance version", PROVENANCE_VERSION);
            console2.log("Every other check passed. Sign this digest with the deployer (cast wallet sign --no-hash):");
            console2.logBytes32(digest);
            console2.log("Put the signature in deployerSignature, set provenanceVersion to match and run verify again.");
            revert ResignProvenance(version, PROVENANCE_VERSION, digest);
        }
        if (version != PROVENANCE_VERSION) revert UnexpectedDeploymentState("provenanceVersion");
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, d.deployerSignature);
        if (err != ECDSA.RecoverError.NoError || signer != deployer) {
            revert UnexpectedDeploymentState("deployerSignature");
        }
    }

    /// @dev Signs with the script's wallet for `deployer`. Without one (a dry run, or a hardware wallet that can't
    /// sign a raw digest) it logs the digest and returns nothing.
    function _signProvenance(address deployer, bytes32 digest) internal virtual returns (bytes memory) {
        try vm.sign(deployer, digest) returns (uint8 v, bytes32 r, bytes32 s) {
            return abi.encodePacked(r, s, v);
        } catch {
            console2.log("No wallet for the deployer. Before verify, sign this digest with cast wallet sign --no-hash:");
            console2.logBytes32(digest);
            return "";
        }
    }

    /// @dev Everything before the last `/`.
    function _parentDir(string memory path) internal pure returns (string memory dir) {
        bytes memory b = bytes(path);
        uint256 end = b.length;
        while (end != 0 && b[end - 1] != "/") --end;
        if (end == 0) return ".";
        dir = new string(end - 1);
        bytes memory d = bytes(dir);
        for (uint256 i = 0; i < end - 1; ++i) {
            d[i] = b[i];
        }
    }

    function _requireCode(address account, string memory field) internal view {
        if (account.code.length == 0) revert UnexpectedDeploymentState(field);
    }

    /// @dev Requires `account` to run the code `initCode` builds when it runs at `account`: the initcode is put in
    /// place of the deployed code and called, which runs the constructor there and returns the runtime code it would
    /// have deployed, immutables set, and the state snapshot then puts everything back. Running at `account` keeps the
    /// rebuild faithful even to a constructor that checks its own address, as `VenueFactory`'s does.
    function _requireSourceCode(address account, bytes memory initCode, string memory field) internal {
        bytes memory deployed = account.code;
        uint256 snapshot = vm.snapshotState();
        vm.etch(account, initCode);
        // Initcode has no ABI: a raw call is how it runs at an address, as forge-std's `deployCodeTo` runs it.
        // forge-lint: disable-next-line(low-level-calls)
        (bool built, bytes memory rebuilt) = account.call(new bytes(0));
        if (!vm.revertToStateAndDelete(snapshot)) revert UnexpectedDeploymentState(field);
        if (!built || !sameExecutableCode(deployed, rebuilt)) revert UnexpectedDeploymentState(field);
    }

    /// @notice Whether `deployed` is `rebuilt` but for the CBOR metadata trailer: the same length, and the same bytes
    /// before the trailer, whose length `rebuilt`'s last two bytes give. The trailer hashes every source file's text
    /// and the remappings, so it changes with a comment or a submodule checkout while no executable byte does. The
    /// trailer's bytes in `deployed` are unreachable: every jump the code makes lands before it.
    /// @dev Public, and called internally on memory: `this.sameExecutableCode(...)` would read `address(this)`, which
    /// Forge refuses in a script contract ("Usage of `address(this)` detected in script contract"), so `run` and
    /// `verify` would revert in a real `forge script` run although `forge test` passes. CI runs both as a script.
    function sameExecutableCode(bytes memory deployed, bytes memory rebuilt) public pure returns (bool same) {
        uint256 length = rebuilt.length;
        if (deployed.length != length || length < 2) return false;
        uint256 executable = length - 2;
        uint256 trailer = (uint256(uint8(rebuilt[executable])) << 8) | uint256(uint8(rebuilt[executable + 1]));
        if (trailer > executable) return false;
        executable -= trailer;
        assembly ("memory-safe") {
            same := eq(keccak256(add(deployed, 0x20), executable), keccak256(add(rebuilt, 0x20), executable))
        }
    }

    function _logDeployment(Deployment memory d) internal pure {
        console2.log("Venue implementation", address(d.implementation));
        console2.log("Settler", address(d.settler));
        console2.log("VenueFactory", address(d.factory));
    }

    function _writeManifest(
        string memory network,
        Config memory config,
        Deployment memory d,
        string memory status,
        uint256 startBlock,
        string memory path
    ) internal virtual {
        // Each serialize call returns its object so far; only the last call's result is used.
        // forge-lint: disable-start(unused-return)
        string memory contractsKey = "contracts";
        vm.serializeAddress(contractsKey, "settler", address(d.settler));
        vm.serializeAddress(contractsKey, "venueFactory", address(d.factory));
        vm.serializeAddress(contractsKey, "venueImplementation", address(d.implementation));
        string memory contracts = vm.serializeAddress(contractsKey, "registry", address(d.registry));

        string memory roles = vm.serializeAddress("roles", "registryAdmin", config.registryAdmin);

        string memory rootKey = "propamm-v2";
        vm.serializeString(rootKey, "network", network);
        vm.serializeUint(rootKey, "chainId", block.chainid);
        vm.serializeString(rootKey, "status", status);
        // run records the simulation head. verify bounds this unsigned hint, but cannot prove its deployment relationship.
        vm.serializeUint(rootKey, "startBlock", startBlock);
        vm.serializeAddress(rootKey, "deployer", config.deployer);
        vm.serializeUint(rootKey, "deployerNonce", d.deployerNonce);
        vm.serializeBytes(rootKey, "deployerSignature", d.deployerSignature);
        vm.serializeUint(rootKey, "provenanceVersion", PROVENANCE_VERSION);
        vm.serializeBytes32(rootKey, "registryCreationTx", d.registryCreationTx);
        vm.serializeString(rootKey, "contracts", contracts);
        string memory json = vm.serializeString(rootKey, "roles", roles);
        // forge-lint: disable-end(unused-return)

        vm.createDir(_parentDir(path), true);
        vm.writeJson(json, path);
        console2.log("Manifest", path);
        console2.log("Manifest status", status);
    }
}
