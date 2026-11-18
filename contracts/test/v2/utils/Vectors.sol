// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";

/// @dev The shared vectors the Solidity, Rust and TypeScript suites replay: the committed file that
/// `contracts/test/vectors/ladder-reference.mjs` generates, or the file `PROPAMM_VECTORS` names, a seeded random set from
/// `contracts/test/vectors/fuzz.mjs` in the same format. Forge reads only under `contracts/test/vectors`
/// (`fs_permissions`), where `fuzz.mjs` writes.
library Vectors {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant COMMITTED = "contracts/test/vectors/propamm-v2-ladder.json";

    function path() internal view returns (string memory) {
        return VM.envOr("PROPAMM_VECTORS", COMMITTED);
    }

    /// @dev True for the committed file, whose coverage of every outcome the suites also assert. A random set is only
    /// held to the reference.
    function committed() internal view returns (bool) {
        return keccak256(bytes(path())) == keccak256(bytes(COMMITTED));
    }

    function json() internal view returns (string memory) {
        return VM.readFile(path());
    }
}
