pragma solidity >=0.5.12 <=0.6.2;

/**
 * @title Trader
 * @notice Proxy contract for pool
 * @author Primitive
 */

import { IERC20 } from "../interfaces/IERC20.sol";
import { SafeERC20 } from "../libraries/SafeERC20.sol";
import { SafeMath } from "../libraries/SafeMath.sol";
import { IBPool } from "../interfaces/IBPool.sol";
import { ILendingPool } from "../interfaces/ILendingPool.sol";

import "@nomiclabs/buidler/console.sol";

contract Trader {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    ILendingPool public lendingPool;

    function initialize(address lendingPoolAddress) public {
        lendingPool = ILendingPool(lendingPoolAddress);
    }

    function buyOption(address optionPoolAddress, uint256 amount) public {
        // borrow 1 unit of risky asset from lending pool
        // transfer premium (say $1) from user to this address
        // deposit liquidity to pool
        // send lp share to lending pool as collateral
        // mint some tokenized form of receipt for purchasing the option
        IBPool optionPool = IBPool(optionPoolAddress);
        address[] memory tokens = optionPool.getFinalTokens();
        address underlyingToken = tokens[0];
        address quoteToken = tokens[1];
        console.log(IERC20(underlyingToken).symbol(), IERC20(quoteToken).symbol());
        lendingPool.borrow(address(this), underlyingToken, 1 ether);
        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(underlyingToken).approve(address(optionPool), uint256(-1));
        IERC20(quoteToken).approve(address(optionPool), uint256(-1));
        (uint poolAmountOut) = optionPool.joinswapExternAmountIn(underlyingToken, 1 ether, uint256(0));
        poolAmountOut = poolAmountOut.add(optionPool.joinswapExternAmountIn(quoteToken, amount, uint256(0)));
        // transfer pool shares out
        optionPool.transfer(msg.sender, poolAmountOut);
    }
}
