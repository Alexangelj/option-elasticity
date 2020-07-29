pragma solidity >=0.5.12 <=0.6.2;

/**
 * @title Option Pool wrapping a Geometric Mean Automated Market Maker Pool.
 */

import { IOptionPool } from "../interfaces/IOptionPool.sol";
import { IBPool } from "../interfaces/IBPool.sol";
import { PoolToken } from "../tokens/PoolToken.sol";
import { ReentrancyGuard } from "../utils/ReentrancyGuard.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { SafeERC20 } from "../libraries/SafeERC20.sol";


contract OptionPool is IOptionPool, PoolToken, ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;
    
    struct Controllers {
        IBPool optionPool;
        address controller;
        address tokenBinder;
    }

    Controllers public controllers;

    modifier onlyController {
        require(msg.sender == controllers.controller, "ERR_NOT_CONTROLLER");
        _;
    }

    modifier onlyBinder {
        require(msg.sender == controllers.tokenBinder, "ERR_NOT_BINDER");
        _;
    }

    function initialize(address optionPool_, string calldata name_, string calldata symbol_, uint initialSupply_) external {
        require(optionPool_ != address(0x0), "ERR_ZERO_ADDRESS");
        require(initialSupply_ > 0, "ERR_ZERO_SUPPLY);
        Controllers storage controllers_ = controllers;
        controllers_.optionPool = IBPool(optionPool_);
        controlles_.controller = msg.sender;
        controllers_.tokenBinder = msg.sender;
        _setupName(name_);
        _setupSymbol(symbol_);
        _mintPoolToken(initialSupply_);
    }

    function _mintPoolToken(address to, uint quantity) internal {
        _mint(to, quantity);
    }
}