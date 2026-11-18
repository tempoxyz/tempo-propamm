// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeployV2 } from "../../../script/v2/DeployV2.s.sol";

/// @notice CI's guard that `DeployV2` runs as a Forge script, not only under `forge test`. Forge enforces script-only
/// rules in `forge script` alone, such as refusing `address(this)` in the script contract, so a `run` or `verify` that
/// breaks one passes every test and reverts for the operator. This runs `run` and then `verify` against what `run`
/// just deployed, in one local simulation; the verify workflow runs it, and `DeployV2` itself, with `--network tempo`
/// (the precompiles) and no RPC or `--broadcast`:
///
/// ```bash
/// forge script contracts/test/v2/script/DeployV2RunVerify.s.sol:DeployV2RunVerify \
///   --sig 'runAndVerify()' --network tempo --chain 42431 --sender 0x…
/// ```
///
/// CI runs it with `--chain 42431` and again with `--chain 4217`, whose mainnet-only branches (the manifest's network name) run nowhere else as a script. Without `--sig 'runAndVerify()'` Forge calls the
/// inherited `run` alone and never reaches `verify`.
///
/// @dev Both entry points share one manifest under the test cache, so `verify` reads the one `run` wrote and nothing
/// under `deployments/` changes.
contract DeployV2RunVerify is DeployV2 {
    /// @dev A key for this simulation alone, derived from a public string: it holds nothing, and the script never
    /// broadcasts. The deployer is its address, whatever `--sender` says, so `run` signs the provenance digest with it
    /// as an operator's wallet would, and `verify` checks that signature.
    uint256 internal constant DEPLOYER_KEY = uint256(keccak256("propAMM DeployV2RunVerify deployer"));

    function runAndVerify() external {
        vm.rememberKey(DEPLOYER_KEY);
        run();
        verify();
    }

    function _readConfig() internal view override returns (Config memory config) {
        config = super._readConfig();
        config.deployer = vm.addr(DEPLOYER_KEY);
    }

    function _manifestPath(string memory network, bool) internal pure override returns (string memory) {
        return string.concat("cache/propamm-v2-deploy-test/", network, "-script-run-verify.json");
    }
}
