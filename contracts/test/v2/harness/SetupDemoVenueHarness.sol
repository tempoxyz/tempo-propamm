// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SetupDemoVenue } from "../../../script/v2/SetupDemoVenue.s.sol";

/// @dev Reads its inputs from storage instead of the process environment, which parallel tests share.
contract SetupDemoVenueHarness is SetupDemoVenue {
    bytes internal encoded;

    function setInput(Config calldata config) external {
        encoded = abi.encode(config);
    }

    /// @notice The real environment reader, for the one test that sets the environment.
    function readEnvConfig() external view returns (Config memory) {
        return super._readConfig();
    }

    function _readConfig() internal view override returns (Config memory) {
        return abi.decode(encoded, (Config));
    }
}
