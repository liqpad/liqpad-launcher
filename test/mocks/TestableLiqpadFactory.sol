// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {LiqpadFactory} from "../../src/LiqpadFactory.sol";

contract TestableLiqpadFactory is LiqpadFactory {
    IB20Factory private immutable _mockFactory;

    constructor(IB20Factory mockFactory_) {
        _mockFactory = mockFactory_;
    }

    function _b20Factory() internal view override returns (IB20Factory) {
        return _mockFactory;
    }
}

