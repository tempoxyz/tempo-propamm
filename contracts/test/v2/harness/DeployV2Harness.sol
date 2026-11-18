// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeployV2 } from "../../../script/v2/DeployV2.s.sol";

/// @dev EVM storage is isolated per test; process environment variables and files are not. Every test but one reads
/// its inputs from this harness and writes its manifest to its own file under `cache/`.
contract DeployV2Harness is DeployV2 {
    Config internal input;
    bool internal useEnv;
    string internal manifestFile;
    /// @dev The deployer's key, which tests know from `makeAddrAndKey`; 0 leaves signing to the script's wallets.
    uint256 internal signingKey;

    function setSigningKey(uint256 key) external {
        signingKey = key;
    }

    function setInput(Config calldata config) external {
        input = config;
    }

    function setUseEnv(bool value) external {
        useEnv = value;
    }

    function setManifestFile(string calldata path) external {
        manifestFile = path;
    }

    function defaultManifestPath(string calldata network, bool dryRun) external view returns (string memory) {
        return super._manifestPath(network, dryRun);
    }

    function _readConfig() internal view override returns (Config memory) {
        return useEnv ? super._readConfig() : input;
    }

    function _manifestPath(string memory, bool) internal view override returns (string memory) {
        return manifestFile;
    }

    function _signProvenance(address deployer, bytes32 digest) internal override returns (bytes memory) {
        if (signingKey == 0) return super._signProvenance(deployer, digest);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Suites that only need the deployed core leave the manifest file unset and write nothing.
    function _writeManifest(
        string memory network,
        Config memory config,
        Deployment memory d,
        string memory status,
        uint256 startBlock,
        string memory path
    ) internal override {
        if (bytes(manifestFile).length != 0) {
            super._writeManifest(network, config, d, status, startBlock, path);
        }
    }
}
