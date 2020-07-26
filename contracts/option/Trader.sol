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

    function getTokens(IBPool optionPool) public view returns (address underlyingToken, address quoteToken) {
        address[] memory tokens = optionPool.getFinalTokens();
        underlyingToken = tokens[0];
        quoteToken = tokens[1];
    }

    // can be a library function
    function _checkApproval(address token, address spender, uint amount) internal returns (bool) {
        if (IERC20(token).allowance(address(this), spender) < amount) {
                return IERC20(token).approve(address(spender), uint(-1));
        }
        return true;
    }

    // needs to check optionPoolAddress
    function buyOption(address optionPoolAddress, uint256 amount) public {
        IBPool optionPool = IBPool(optionPoolAddress);
        (address underlyingToken, address quoteToken) = getTokens(optionPool);
        // approve the tokens to be transferred into the pool
        _checkApproval(underlyingToken, address(optionPool), 1 ether);
        _checkApproval(quoteToken, address(optionPool), amount);
        // transfer premium (say $1) from user to this address
        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), amount);
        // borrow 1 unit of risky asset from lending pool
        lendingPool.borrow(address(this), underlyingToken, 1 ether);
        // deposit liquidity to pool
        //console.log(optionPool.getBalance(underlyingToken), optionPool.getBalance(quoteToken));
        // FIX - need to calculate net of fees amount of lp tokens out
        uint underlyingOut = uint(0);
        uint quoteOut = uint(0);
        (uint poolAmountOut) = optionPool.joinswapExternAmountIn(underlyingToken, 1 ether / 100, underlyingOut);
        poolAmountOut = poolAmountOut.add(optionPool.joinswapExternAmountIn(quoteToken, amount, quoteOut));
        // send lp share to lending pool as collateral
        // transfer pool shares out
        _checkApproval(address(optionPool), address(lendingPool), poolAmountOut);
        lendingPool.depositCollateral(address(this), msg.sender, address(optionPool), poolAmountOut);
        // mint some tokenized form of receipt for purchasing the option
    }

    function _borrowJoinDepositCollateral() internal returns (bool) {

    }

    function calculatePoolAmountOut(IBPool optionPool, address token, uint amount) public returns (uint poolAmountOut) {
        // get tokens
        address[] memory tokens = optionPool.getFinalTokens();
        // fail early
        require(tokens[0] == token || tokens[1] == token, "ERR_INVALID_TOKEN");
        poolAmountOut = calculateProportion(amount, optionPool.totalSupply(), optionPool.getBalance(token));
    }

    function calculateProportion(uint amount, uint totalSupply, uint balance) public returns (uint) {
        uint out = amount.mul(totalSupply).div(balance);
        out = out.sub(out.div((10**18 / 10**6)));
        return out;
    }

    function calculatePoolAmountsOut(IBPool optionPool, uint[] memory amounts) public returns (uint poolAmountOut) {
        uint totalSupply = optionPool.totalSupply();

        // get amounts and tokens
        uint underlyingAmount = amounts[0];
        uint quoteAmount = amounts[1];
        address[] memory tokens = optionPool.getFinalTokens();
        address underlyingToken = tokens[0];
        address quoteToken = tokens[1];
        uint underlyingBalance = optionPool.getBalance(underlyingToken);
        uint quoteBalance = optionPool.getBalance(quoteToken);

        // user token balance * total supply / pool token balance = pool amount out
        poolAmountOut = underlyingAmount.mul(totalSupply).div(underlyingBalance);
        poolAmountOut = poolAmountOut.add(quoteAmount.mul(totalSupply).div(quoteBalance)).sub(uint(1));
    }

    function borrowHook(IBPool optionPool, address underlyingToken, address quoteToken, uint underlyingQuantity, uint quoteQuantity) public {
        // deposit liquidity to pool
        (uint poolAmountOut) = optionPool.joinswapExternAmountIn(underlyingToken, underlyingQuantity, uint256(0));
        poolAmountOut = poolAmountOut.add(optionPool.joinswapExternAmountIn(quoteToken, quoteQuantity, uint256(0)));
        // send lp share to lending pool as collateral
        // transfer pool shares out
        lendingPool.depositCollateral(address(this), msg.sender, address(optionPool), poolAmountOut);
        // mint some tokenized form of receipt for purchasing the option
    }
}
