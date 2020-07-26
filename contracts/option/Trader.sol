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
        position.underlyingToken = underlyingToken;
        position.optionPool = optionPool;
        position.quoteToken = quoteToken;
        position.lotSize = lotSize;
        position.premium = premium;
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
        return _borrow(position.optionPool, position.underlyingToken, position.lotSize);
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
        uint256 poolAmountOut = _enterPool(IBPool(optionPool), token, input);
        return _depositCollateral(optionPool, poolAmountOut);

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
    }

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
