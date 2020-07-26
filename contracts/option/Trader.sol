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
import { ISecuredLoanReceiver } from "../interfaces/ISecuredLoanReceiver.sol";

import "@nomiclabs/buidler/console.sol";

contract Trader is ISecuredLoanReceiver {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    ILendingPool public lendingPool;

    function initialize(address lendingPoolAddress) public {
        lendingPool = ILendingPool(lendingPoolAddress);
    }

    function getTokens(IBPool optionPool)
        public
        view
        returns (address underlyingToken, address quoteToken)
    {
        address[] memory tokens = optionPool.getFinalTokens();
        underlyingToken = tokens[0];
        quoteToken = tokens[1];
    }

    // can be a library function
    function _checkApproval(
        address token,
        address spender,
        uint256 amount
    ) internal returns (bool) {
        if (IERC20(token).allowance(address(this), spender) < amount) {
            return IERC20(token).approve(address(spender), uint256(-1));
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
        _pull(quoteToken, amount);
        // borrow 1 unit of risky asset from lending pool
        _borrow(optionPool, underlyingToken, 1 ether);
        // deposit liquidity to pool
        //console.log(optionPool.getBalance(underlyingToken), optionPool.getBalance(quoteToken));
        // FIX - need to calculate net of fees amount of lp tokens out
        /* uint underlyingOut = uint(0);
        uint quoteOut = uint(0);
        (uint poolAmountOut) = _enterPool(optionPool, underlyingToken, 1 ether / 100, underlyingOut);
        poolAmountOut = poolAmountOut.add(_enterPool(optionPool, quoteToken, amount, quoteOut));
        // send lp share to lending pool as collateral
        // transfer pool shares out
        _depositCollateral(address(optionPool), poolAmountOut); */
        // mint some tokenized form of receipt for purchasing the option
    }

    function secureLoan(
        IBPool optionPool,
        uint256 loanedQuantity,
        uint256 fee,
        bytes calldata params
    ) external {
        (bool success, bytes memory data) = address(this).call(params);
        require(success, "ERR_CALL_FAILED");
    }

    // funcsig: f4a0fa60
    function _depositAndCollateralize(
        address optionPool,
        address token,
        uint256 input,
        uint256 output
    ) public returns (bool) {
        uint256 poolAmountOut = _enterPool(IBPool(optionPool), token, input, output);
        require(poolAmountOut > 0, "ERR_ENTERING_POOL");
        require(_depositCollateral(optionPool, poolAmountOut), "ERR_DEPOSITING_COLLATERAL");
        return true;
    }

    function _enterPool(
        IBPool optionPool,
        address token,
        uint256 inputQuantity,
        uint256 minOutputQuantity
    ) internal returns (uint256 poolAmountOut) {
        poolAmountOut = optionPool.joinswapExternAmountIn(token, inputQuantity, minOutputQuantity);
    }

    function _depositCollateral(address optionPoolAddress, uint256 poolAmountOut)
        internal
        returns (bool)
    {
        require(
            _checkApproval(optionPoolAddress, address(lendingPool), poolAmountOut),
            "ERR_APPROVALS"
        );
        require(
            lendingPool.depositCollateral(
                address(this),
                address(lendingPool),
                optionPoolAddress,
                poolAmountOut
            ),
            "ERR_DEPOSITING_COLLATERAL"
        );
        return true;
    }

    function _pull(address token, uint256 amount) internal returns (bool) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        return true;
    }

    function _borrow(
        IBPool optionPool,
        address token,
        uint256 amount
    ) internal returns (bool) {
        // should pass in data to deposit and then send lp tokens out
        bytes4 computedSelector = bytes4(
            keccak256(bytes("_depositAndCollateralize(address,address,uint256,uint256)"))
        );
        bytes4 selector = 0xf4a0fa60;
        bytes memory params = abi.encodeWithSelector(
            computedSelector,
            address(optionPool),
            token,
            amount,
            uint256(0)
        );
        lendingPool.borrow(optionPool, address(this), token, amount, params);
        return true;
    }

    function _borrowJoinDepositCollateral() internal returns (bool) {}

    function calculatePoolAmountOut(
        IBPool optionPool,
        address token,
        uint256 amount
    ) public returns (uint256 poolAmountOut) {
        // get tokens
        address[] memory tokens = optionPool.getFinalTokens();
        // fail early
        require(tokens[0] == token || tokens[1] == token, "ERR_INVALID_TOKEN");
        poolAmountOut = calculateProportion(
            amount,
            optionPool.totalSupply(),
            optionPool.getBalance(token)
        );
    }

    function calculateProportion(
        uint256 amount,
        uint256 totalSupply,
        uint256 balance
    ) public returns (uint256) {
        uint256 out = amount.mul(totalSupply).div(balance);
        out = out.sub(out.div((10**18 / 10**6)));
        return out;
    }

    function calculatePoolAmountsOut(IBPool optionPool, uint256[] memory amounts)
        public
        returns (uint256 poolAmountOut)
    {
        uint256 totalSupply = optionPool.totalSupply();

        // get amounts and tokens
        uint256 underlyingAmount = amounts[0];
        uint256 quoteAmount = amounts[1];
        address[] memory tokens = optionPool.getFinalTokens();
        address underlyingToken = tokens[0];
        address quoteToken = tokens[1];
        uint256 underlyingBalance = optionPool.getBalance(underlyingToken);
        uint256 quoteBalance = optionPool.getBalance(quoteToken);

        // user token balance * total supply / pool token balance = pool amount out
        poolAmountOut = underlyingAmount.mul(totalSupply).div(underlyingBalance);
        poolAmountOut = poolAmountOut.add(quoteAmount.mul(totalSupply).div(quoteBalance)).sub(
            uint256(1)
        );
    }

    function borrowHook(
        IBPool optionPool,
        address underlyingToken,
        address quoteToken,
        uint256 underlyingQuantity,
        uint256 quoteQuantity
    ) public {
        // deposit liquidity to pool
        uint256 poolAmountOut = optionPool.joinswapExternAmountIn(
            underlyingToken,
            underlyingQuantity,
            uint256(0)
        );
        poolAmountOut = poolAmountOut.add(
            optionPool.joinswapExternAmountIn(quoteToken, quoteQuantity, uint256(0))
        );
        // send lp share to lending pool as collateral
        // transfer pool shares out
        lendingPool.depositCollateral(
            address(this),
            msg.sender,
            address(optionPool),
            poolAmountOut
        );
        // mint some tokenized form of receipt for purchasing the option
    }
}
