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
import { ReentrancyGuard } from "../utils/ReentrancyGuard.sol";

import "@nomiclabs/buidler/console.sol";

contract Trader is ISecuredLoanReceiver, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    ILendingPool public lendingPool;

    struct SyntheticPosition {
        IBPool optionPool;
        address buyer;
        address underlyingToken;
        address quoteToken;
        uint lotSize;
        uint premium;
        uint lpSharePayment;
    }

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
    function buyOption(address optionPoolAddress, uint256 lotSize) public {
        // get the actual pool
        IBPool optionPool = IBPool(optionPoolAddress);
        // get the pools assets
        (address underlyingToken, address quoteToken) = getTokens(optionPool);
        // get premium
        uint256 premium = 1 ether;
        // approve the tokens to be transferred into the pool
        _checkApproval(underlyingToken, address(optionPool), lotSize);
        // make sure for each option, the full premium can be paid.
        _checkApproval(quoteToken, address(optionPool), premium.mul(lotSize).div(1 ether));
        // initiate transaction
        SyntheticPosition memory position;
        {
        position.optionPool = optionPool;
        position.buyer = msg.sender;
        position.underlyingToken = underlyingToken;
        position.quoteToken = quoteToken;
        position.lotSize = lotSize;
        position.premium = premium;
        }
        //_syntheticPosition(optionPool, underlyingToken, quoteToken, lotSize, premium);
        _syntheticPosition(position);
    }

    function _syntheticPosition(
        SyntheticPosition memory position
    ) internal returns (bool) {
        // everythings about to get put into a maze, so lets track the original buyer
        address buyer = position.buyer;
        // pull the premium for the lot size so we can deposit it into the pool
        _pull(position.quoteToken, position.premium);
        // calculate the expected amount of lp shares received for the deposit
        uint256 minOutput = calcExpectedPoolOut(position.optionPool, position.quoteToken, position.premium);
        // deposit position.premium denominated in quote token and returns LP share tokens
        (uint poolAmountOut) = _enterPool(position.optionPool, position.quoteToken, position.premium);
        // check lp shares have been paid for the corresponding lot size
        require(poolAmountOut >= minOutput, "ERR_INSUFFICIENT_LP");
        // call borrow, borrowing the underlying asset and paying the lp tokens
        // borrow 1 unit of risky asset from lending pool and deposit into pool
        // collateral is lp shares from quote token + lp shares from underlying token deposits
        position.lpSharePayment = poolAmountOut;
        return _borrow(position);
    }

    /* function _syntheticPosition(
        IBPool optionPool,
        address underlyingToken,
        address quoteToken,
        uint256 lotSize,
        uint256 premium
    ) internal returns (bool) {
        // everythings about to get put into a maze, so lets track the original buyer
        address buyer = msg.sender;
        // pull the premium for the lot size so we can deposit it into the pool
        _pull(quoteToken, premium);
        // calculate the expected amount of lp shares received for the deposit
        uint256 minOutput = calcExpectedPoolOut(optionPool, quoteToken, premium);
        // deposit premium denominated in quote token and returns LP share tokens
        (uint poolAmountOut) = _enterPool(optionPool, quoteToken, premium, minOutput);
        // check lp shares have been paid for the corresponding lot size
        require(poolAmountOut >= minOutput, "ERR_INSUFFICIENT_LP");
        // call borrow, borrowing the underlying asset and paying the lp tokens
        // borrow 1 unit of risky asset from lending pool and deposit into pool
        // collateral is lp shares from quote token + lp shares from underlying token deposits
        return _borrow(optionPool, underlyingToken, lotSize);
    } */

    function calcExpectedPoolOut(IBPool optionPool, address inputToken, uint tokenAmountIn) public view returns (uint poolAmountOut) {
        uint tokenBalanceIn;
        uint tokenWeightIn;
        {
        (address token0, address token1) = getTokens(optionPool);
        uint balanceToken0 = optionPool.getBalance(token0);
        uint balanceToken1 = optionPool.getBalance(token1);
        uint weightToken0 = optionPool.getDenormalizedWeight(token0);
        uint weightToken1 = optionPool.getDenormalizedWeight(token1);
        tokenBalanceIn = token0 == inputToken ? balanceToken0 : balanceToken1;
        tokenWeightIn = token0 == inputToken ? weightToken0 : weightToken1;
        }
        poolAmountOut = optionPool.calcPoolOutGivenSingleIn(tokenBalanceIn, tokenWeightIn, optionPool.totalSupply(), optionPool.getTotalDenormalizedWeight(), tokenAmountIn, optionPool.getSwapFee());
    }

    function secureLoan(
        IBPool optionPool,
        uint256 loanedQuantity,
        uint256 fee,
        bytes calldata params
    ) external returns (bool) {
        (bool success, bytes memory data) = address(this).call(params);
        require(success, "ERR_SECURE_LOAN_CALL_FAIL");
        return success;
    }

    // funcsig: f4a0fa60
    function _depositAndCollateralize(
        address buyer,
        address optionPool,
        address token,
        uint256 input,
        uint256 payment
    ) public returns (bool) {
        uint256 poolAmountOut = _enterPool(IBPool(optionPool), token, input).add(payment);
        return _depositCollateral(buyer, input, token, optionPool, poolAmountOut);

    }

    function _enterPool(
        IBPool optionPool,
        address token,
        uint256 inputQuantity
    ) internal returns (uint256 poolAmountOut) {
        uint256 minOutput = calcExpectedPoolOut(optionPool, token, inputQuantity);
        (poolAmountOut) = optionPool.joinswapExternAmountIn(token, inputQuantity, minOutput);
        require(poolAmountOut >= minOutput && poolAmountOut > 0, "ERR_INSUFFICIENT_LP");
    }

    function _depositCollateral(address buyer, uint debt, address borrowedToken, address optionPoolAddress, uint256 poolAmountOut)
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
                buyer,
                optionPoolAddress,
                borrowedToken,
                debt,
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
        SyntheticPosition memory position
    ) internal nonReentrant returns (bool) {
        // should pass in data to deposit and then send lp tokens out
        bytes4 selector = bytes4(
            keccak256(bytes("_depositAndCollateralize(address,address,address,uint256,uint256)"))
        );
        bytes memory params = abi.encodeWithSelector(
            selector,
            position.buyer,
            address(position.optionPool),
            position.underlyingToken,
            position.lotSize,
            position.lpSharePayment
        );
        return lendingPool.borrow(position.optionPool, address(this), position.underlyingToken, position.lotSize, params);
    }

    /* function _borrow(
        IBPool optionPool,
        address token,
        uint256 amount
    ) internal nonReentrant returns (bool) {
        // should pass in data to deposit and then send lp tokens out
        bytes4 selector = bytes4(
            keccak256(bytes("_depositAndCollateralize(address,address,uint256,uint256)"))
        );
        bytes memory params = abi.encodeWithSelector(
            selector,
            address(optionPool),
            token,
            amount,
            uint256(0)
        );
        return lendingPool.borrow(optionPool, address(this), token, amount, params);
    } */
}
