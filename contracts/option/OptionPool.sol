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
import { Pricing } from "../Pricing.sol";
import { SafeMath } from "../libraries/SafeMath.sol";


contract OptionPool is IOptionPool, PoolToken, ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    event ControllerUpdated(address indexed caller, address indexed oldController, address indexed newController);
    event TokenBinderUpdated(address indexed caller, address indexed oldTokenBinder, address indexed newTokenBinder);
    event LOG_JOIN(
        address indexed caller,
        address indexed tokenIn,
        uint256         tokenAmountIn
    );

    event LOG_EXIT(
        address indexed caller,
        address indexed tokenOut,
        uint256         tokenAmountOut
    );

    struct Controllers {
        IBPool optionPool;
        address controller;
        address tokenBinder;
    }

    struct Parameters {
        uint spot;
        uint strike;
        uint vol;
        uint expiry;
    }

    Controllers public controllers;
    Parameters public parameters;

    // Modifiers

    modifier onlyController {
        require(msg.sender == controller(), "ERR_NOT_CONTROLLER");
        _;
    }

    modifier onlyBinder {
        require(msg.sender == tokenBinder(), "ERR_NOT_BINDER");
        _;
    }

    // Pseudo constructor

    function initialize(
        address optionPool_,
        string calldata name_,
        string calldata symbol_,
        uint initialSupply,
        uint spot_,
        uint strike_,
        uint vol_,
        uint expiry_
    ) external {
        require(optionPool_ != address(0x0), "ERR_ZERO_ADDRESS");
        require(initialSupply > 0, "ERR_ZERO_SUPPLY");
        controllers.optionPool = IBPool(optionPool_);
        controllers.controller = msg.sender;
        controllers.tokenBinder = msg.sender;
        {
        parameters.spot = spot_;
        parameters.strike = strike_;
        parameters.vol = vol_;
        parameters.expiry = expiry_;
        }
        _setupName(name_);
        _setupSymbol(symbol_);
        _mintPoolShare(initialSupply);
        _pushPoolShare(msg.sender, initialSupply);
    }

    // Controller functions

    function setController(address newController) external onlyController nonReentrant {
        emit ControllerUpdated(msg.sender, controllers.controller, newController);
        controllers.controller = newController;
    }

    function setTokenBinder(address newTokenBinder) external onlyBinder nonReentrant {
        emit TokenBinderUpdated(msg.sender, controllers.tokenBinder, newTokenBinder);
        controllers.tokenBinder = newTokenBinder;
    }

    // Binding functions

    function getAmounts(uint256 riskyWeight, uint256 riskFreeWeight)
        public
        pure
        returns (uint256 riskyAmount, uint256 riskFreeAmount)
    {
        uint256 riskyPrice = 100 ether; // 1 per 100
        uint256 riskFreePrice = 10000 ether; //
        // 100 * 10 ^ 18, 5.6 * 10 ^ 18. 100 / 5.6 = 17.85
        riskyAmount = riskyPrice.mul(riskyWeight).div(1 ether);
        riskFreeAmount = riskFreePrice.mul(riskFreeWeight).div(1 ether);
    }

    function _updateWeights() internal {
        IBPool optionPool_ = optionPool();
        address[] memory tokens = optionPool_.getCurrentTokens();
        Parameters memory params = parameters;
        (uint256 riskyWeight, uint256 riskFreeWeight) = Pricing.getWeights(params.spot, params.strike, params.vol, params.expiry.sub(block.timestamp));
        (uint256 riskyAmount, uint256 riskFreeAmount) = getAmounts(riskyWeight, riskFreeWeight);
        _rebind(address(tokens[0]), riskyAmount, riskyWeight.mul(25));
        _rebind(address(tokens[1]), riskFreeAmount, riskFreeWeight.mul(25)); // bone == 50, 25 == half
    }

    function bind(address token_, uint balance, uint denorm) public onlyBinder {
        _bind(token_, balance, denorm);
    }

    function _bind(address token_, uint balance, uint denorm) internal nonReentrant {
        IBPool optionPool_ = optionPool();
        IERC20 token = IERC20(token_);
        token.safeTransferFrom(msg.sender, address(this), balance);
        token.approve(address(optionPool_), uint(-1));
        optionPool_.bind(token_, balance, denorm);
    }

    function rebind(address token_, uint balance, uint denorm) public onlyBinder {
        _rebind(token_, balance, denorm);
    }

    function _rebind(address token_, uint balance, uint denorm) internal nonReentrant {
        IBPool optionPool_ = optionPool();
        IERC20 token = IERC20(token_);

        optionPool_.gulp(token_);

        uint previousBalance = token.balanceOf(address(optionPool_));

        if(balance > previousBalance) {
            token.safeTransferFrom(msg.sender, address(this), balance.sub(previousBalance));
            token.approve(address(optionPool_), uint(-1));
        }

        optionPool_.rebind(token_, balance, denorm);

        _checkDustBalance(token);
    }

    function unbind(address token_) external onlyBinder nonReentrant {
        IBPool optionPool_ = optionPool();
        IERC20 token = IERC20(token_);

        optionPool_.unbind(token_);

        _checkDustBalance(token);
    }

    function _checkDustBalance(IERC20 token) internal {
        uint tokenBalance = token.balanceOf(address(this));
        if(tokenBalance > 0) {
            token.safeTransfer(msg.sender, tokenBalance);
        }
    }

    // Pool Share Functions

    function joinPool(uint poolAmountOut, uint[] calldata maxAmountsIn)
        external
        nonReentrant
    {
        uint poolTotal = totalSupply;
        uint ratio = SafeMath.div(poolAmountOut, poolTotal);
        require(ratio != 0, "ERR_MATH_APPROX");

        IBPool optionPool_ = optionPool();
        address[] memory tokens = optionPool_.getCurrentTokens();
        uint tokensLength = tokens.length;

        for (uint i = 0; i < tokensLength; i++) {
            address t = tokens[i];
            uint bal = optionPool_.getBalance(t);
            uint tokenAmountIn = SafeMath.mul(ratio, bal);
            require(tokenAmountIn != 0, "ERR_MATH_APPROX");
            require(tokenAmountIn <= maxAmountsIn[i], "ERR_LIMIT_IN");
            emit LOG_JOIN(msg.sender, t, tokenAmountIn);
            _pullUnderlying(t, msg.sender, tokenAmountIn, bal);
        }
        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
    }

    function exitPool(uint poolAmountIn, uint[] calldata minAmountsOut)
        external
        nonReentrant
    {
        uint poolTotal = totalSupply;
        uint ratio = SafeMath.div(poolAmountIn, poolTotal);
        require(ratio != 0, "ERR_MATH_APPROX");

        _pullPoolShare(msg.sender, poolAmountIn);
        _burnPoolShare(poolAmountIn);

        IBPool optionPool_ = optionPool();
        address[] memory tokens = optionPool_.getCurrentTokens();
        uint tokensLength = tokens.length;

        for (uint i = 0; i < tokensLength; i++) {
            address t = tokens[i];
            uint bal = optionPool_.getBalance(t);
            uint tokenAmountOut = SafeMath.mul(ratio, bal);
            require(tokenAmountOut != 0, "ERR_MATH_APPROX");
            require(tokenAmountOut >= minAmountsOut[i], "ERR_LIMIT_OUT");
            emit LOG_EXIT(msg.sender, t, tokenAmountOut);
            _pushUnderlying(t, msg.sender, tokenAmountOut, bal);
        }
    }

    // Single Entry and Exit Functions

    function joinswapExternAmountIn(address tokenIn, uint tokenAmountIn, uint minPoolAmountOut)
        external
        nonReentrant
        returns (uint poolAmountOut)

    {
        IBPool optionPool_ = optionPool();
        require(optionPool_.isBound(tokenIn), "ERR_NOT_BOUND");

        poolAmountOut = optionPool_.calcPoolOutGivenSingleIn(
                            optionPool_.getBalance(tokenIn),
                            optionPool_.getDenormalizedWeight(tokenIn),
                            totalSupply,
                            optionPool_.getTotalDenormalizedWeight(),
                            tokenAmountIn,
                            optionPool_.getSwapFee()
                        );

        require(poolAmountOut >= minPoolAmountOut, "ERR_LIMIT_OUT");

        emit LOG_JOIN(msg.sender, tokenIn, tokenAmountIn);

        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
        uint totalBalance = optionPool_.getBalance(tokenIn);
        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn, totalBalance);

        return poolAmountOut;
    }

    // Accounting functions

    function _pushUnderlying(address token, address to, uint quantity, uint totalPoolTokenBalance) internal {
        IBPool optionPool_ = optionPool();
        uint weight = optionPool_.getDenormalizedWeight(token);
        optionPool_.rebind(token, totalPoolTokenBalance.sub(quantity), weight);
        IERC20(token).safeTransfer(to, quantity);
    }

    /**
     * @dev Safe Transfer From assets and rebind the pool accordingly.
     */
    function _pullUnderlying(address token_, address from_, uint quantity_, uint totalTokenBalance_) internal {
        IBPool optionPool_ = optionPool();
        uint weight = optionPool_.getDenormalizedWeight(token_);
        IERC20(token_).safeTransferFrom(from_, address(this), quantity_);
        optionPool_.rebind(token_, totalTokenBalance_.add(quantity_), weight);
    }

    function _mintPoolShare(uint quantity) internal {
        _mint(address(this), quantity);
    }

    function _pullPoolShare(address from, uint quantity) internal {
        IERC20(address(this)).safeTransferFrom(from, address(this), quantity);
    }

    function _pushPoolShare(address to, uint quantity) internal {
        IERC20(address(this)).safeTransfer(to, quantity);
    }

    function _burnPoolShare(uint quantity) internal {
        _burn(address(this), quantity);
    }

    // View functions

    function getDenormalizedWeight(address token_) external view returns (uint) {
        return optionPool().getDenormalizedWeight(token_);
    }

    function isPublicSwap() external view returns(bool) {
        return optionPool().isPublicSwap();
    }

    function getSwapFee() external view returns(bool) {
        return optionPool().getSwapFee();
    }

    function controller() public view returns (address) {
        return controllers.controller;
    }

    function optionPool() public view returns (IBPool) {
        return controllers.optionPool;
    }

    function tokenBinder() public view returns (address) {
        return controllers.tokenBinder;
    }
    
}