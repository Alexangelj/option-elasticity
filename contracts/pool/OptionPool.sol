pragma solidity >=0.5.12 <=0.6.2;

/**
 * @title Option Pool wrapping a Geometric Mean Automated Market Maker Pool.
 */

// Primitive
import { ERC20 } from "../tokens/ERC20.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { IOptionPool } from "./interfaces/IOptionPool.sol";
import { IProxyPriceProvider } from "../oracle/interfaces/IProxyPriceProvider.sol";

// Balancer
import { BNum } from "../libraries/BNum.sol";
import { IBPool } from "./interfaces/IBPool.sol";

// Open Zeppelin
import { Pricing } from "../Pricing.sol";
import { ReentrancyGuard } from "../utils/ReentrancyGuard.sol";
import { SafeERC20 } from "../libraries/SafeERC20.sol";
import { SafeMath } from "../libraries/SafeMath.sol";

import "@nomiclabs/buidler/console.sol";

contract OptionPool is IOptionPool, ERC20, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event ControllerUpdated(
        address indexed caller,
        address indexed oldController,
        address indexed newController
    );
    event TokenBinderUpdated(
        address indexed caller,
        address indexed oldTokenBinder,
        address indexed newTokenBinder
    );
    event LOG_JOIN(address indexed caller, address indexed tokenIn, uint256 tokenAmountIn);

    event LOG_EXIT(address indexed caller, address indexed tokenOut, uint256 tokenAmountOut);

    struct Controllers {
        IBPool optionPool;
        address controller;
        address tokenBinder;
    }

    struct Parameters {
        uint256 spot;
        uint256 strike;
        uint256 vol;
        uint256 expiry;
    }

    struct Assets {
        address underlyingToken;
        address quoteToken;
    }

    Controllers public controllers;
    Parameters public parameters;
    Assets public assets;
    IProxyPriceProvider public priceProvider;

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
        address priceProvider_,
        string calldata name_,
        string calldata symbol_,
        uint256 initialSupply,
        address underlyingToken_,
        address quoteToken_,
        uint256 strike_,
        uint256 expiry_
    ) external {
        require(optionPool_ != address(0x0), "ERR_ZERO_ADDRESS");
        require(initialSupply > 0, "ERR_ZERO_SUPPLY");
        priceProvider = IProxyPriceProvider(priceProvider_);

        controllers.optionPool = IBPool(optionPool_);
        controllers.controller = msg.sender;
        controllers.tokenBinder = msg.sender;
        {
            parameters.spot = IProxyPriceProvider(priceProvider_).getAssetPrice(underlyingToken_);
            parameters.strike = strike_;
            parameters.vol = IProxyPriceProvider(priceProvider_).getAssetVolatility(
                underlyingToken_
            );
            parameters.expiry = expiry_;
        }
        {
            assets.underlyingToken = underlyingToken_;
            assets.quoteToken = quoteToken_;
        }
        _setupName(name_);
        _setupSymbol(symbol_);
        _mintPoolShare(initialSupply);
        _pushPoolShare(msg.sender, initialSupply);
        _initializeWeights();
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
        view
        returns (uint256 riskyAmount, uint256 riskFreeAmount)
    {
        uint256 riskyPrice = 1 ether; // 1 per 100
        address underlying = assets.underlyingToken;
        uint256 riskFreePrice = priceProvider.getAssetPrice(underlying); //
        // 100 * 10 ^ 18, 5.6 * 10 ^ 18. 100 / 5.6 = 17.85
        riskyAmount = riskyPrice.mul(riskyWeight).div(1 ether);
        riskFreeAmount = riskFreePrice.mul(riskFreeWeight).div(1 ether);
    }

    function _initializeWeights() internal {
        IBPool optionPool_ = optionPool();
        Parameters memory params = parameters;
        Assets memory assets_ = assets;
        (uint256 riskyWeight, uint256 riskFreeWeight) = Pricing.getWeights(
            params.spot,
            params.strike,
            params.vol,
            params.expiry
        );
        (uint256 riskyAmount, uint256 riskFreeAmount) = getAmounts(riskyWeight, riskFreeWeight);
        _bind(assets_.underlyingToken, riskyAmount, riskyWeight.mul(25));
        _bind(assets_.quoteToken, riskFreeAmount, riskFreeWeight.mul(25)); // bone == 50, 25 == half
    }

    function _updateWeights() internal {
        IBPool optionPool_ = optionPool();
        address[] memory tokens = optionPool_.getCurrentTokens();
        Parameters memory params = parameters;
        address underlying = assets.underlyingToken;
        (uint256 riskyWeight, uint256 riskFreeWeight) = Pricing.getWeights(
            priceProvider.getAssetPrice(underlying),
            params.strike,
            priceProvider.getAssetVolatility(underlying),
            params.expiry
        );
        (uint256 riskyAmount, uint256 riskFreeAmount) = getAmounts(riskyWeight, riskFreeWeight);
        _rebind(address(tokens[0]), riskyAmount, riskyWeight.mul(25));
        _rebind(address(tokens[1]), riskFreeAmount, riskFreeWeight.mul(25)); // bone == 50, 25 == half
    }

    function bind(
        address token_,
        uint256 balance,
        uint256 denorm
    ) public onlyBinder {
        _bind(token_, balance, denorm);
    }

    function _bind(
        address token_,
        uint256 balance,
        uint256 denorm
    ) internal nonReentrant {
        IBPool optionPool_ = optionPool();
        IERC20 token = IERC20(token_);
        token.safeTransferFrom(msg.sender, address(this), balance);
        token.approve(address(optionPool_), uint256(-1));
        optionPool_.bind(token_, balance, denorm);
    }

    function rebind(
        address token_,
        uint256 balance,
        uint256 denorm
    ) public onlyBinder {
        _rebind(token_, balance, denorm);
    }

    function _rebind(
        address token_,
        uint256 balance,
        uint256 denorm
    ) internal {
        IBPool optionPool_ = optionPool();
        IERC20 token = IERC20(token_);

        optionPool_.gulp(token_);

        uint256 previousBalance = token.balanceOf(address(optionPool_));

        if (balance > previousBalance) {
            token.safeTransferFrom(msg.sender, address(this), balance.sub(previousBalance));
            token.approve(address(optionPool_), uint256(-1));
        }

        optionPool_.rebind(token_, balance, denorm);

        uint256 tokenBalance = token.balanceOf(address(this));
        if (tokenBalance > 0) {
            token.safeTransfer(msg.sender, tokenBalance);
        }
    }

    function unbind(address token_) external onlyBinder nonReentrant {
        IBPool optionPool_ = optionPool();
        IERC20 token = IERC20(token_);

        optionPool_.unbind(token_);

        uint256 tokenBalance = token.balanceOf(address(this));
        if (tokenBalance > 0) {
            token.safeTransfer(msg.sender, tokenBalance);
        }
    }

    // Pool Share Functions

    function joinPool(uint256 poolAmountOut, uint256[] calldata maxAmountsIn)
        external
        nonReentrant
    {
        uint256 poolTotal = totalSupply;
        uint256 ratio = BNum.bdiv(poolAmountOut, poolTotal);
        require(ratio != 0, "ERR_MATH_APPROX");

        IBPool optionPool_ = optionPool();
        address[] memory tokens = optionPool_.getCurrentTokens();
        uint256 tokensLength = tokens.length;

        for (uint256 i = 0; i < tokensLength; i++) {
            address t = tokens[i];
            uint256 bal = optionPool_.getBalance(t);
            uint256 tokenAmountIn = BNum.bmul(ratio, bal);
            require(tokenAmountIn != 0, "ERR_MATH_APPROX");
            require(tokenAmountIn <= maxAmountsIn[i], "ERR_LIMIT_IN");
            emit LOG_JOIN(msg.sender, t, tokenAmountIn);
            _pullUnderlying(t, msg.sender, tokenAmountIn, bal);
        }
        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
    }

    function exitPool(uint256 poolAmountIn, uint256[] calldata minAmountsOut)
        external
        nonReentrant
    {
        uint256 poolTotal = totalSupply;
        uint256 ratio = BNum.bdiv(poolAmountIn, poolTotal);
        require(ratio != 0, "ERR_MATH_APPROX");

        _pullPoolShare(msg.sender, poolAmountIn);
        _burnPoolShare(poolAmountIn);

        IBPool optionPool_ = optionPool();
        address[] memory tokens = optionPool_.getCurrentTokens();
        uint256 tokensLength = tokens.length;

        for (uint256 i = 0; i < tokensLength; i++) {
            address t = tokens[i];
            uint256 bal = optionPool_.getBalance(t);
            uint256 tokenAmountOut = BNum.bmul(ratio, bal);
            require(tokenAmountOut != 0, "ERR_MATH_APPROX");
            require(tokenAmountOut >= minAmountsOut[i], "ERR_LIMIT_OUT");
            emit LOG_EXIT(msg.sender, t, tokenAmountOut);
            _pushUnderlying(t, msg.sender, tokenAmountOut, bal);
        }
    }

    // Single Entry and Exit Functions

    function joinswapExternAmountIn(
        address tokenIn,
        uint256 tokenAmountIn,
        uint256 minPoolAmountOut
    ) external nonReentrant returns (uint256 poolAmountOut) {
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
        uint256 totalBalance = optionPool_.getBalance(tokenIn);
        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn, totalBalance);

        return poolAmountOut;
    }

    // Accounting functions

    function _pushUnderlying(
        address token,
        address to,
        uint256 quantity,
        uint256 totalPoolTokenBalance
    ) internal {
        IBPool optionPool_ = optionPool();
        uint256 weight = optionPool_.getDenormalizedWeight(token);
        optionPool_.rebind(token, totalPoolTokenBalance.sub(quantity), weight);
        IERC20(token).safeTransfer(to, quantity);
        _updateWeights();
    }

    /**
     * @dev Safe Transfer From assets and rebind the pool accordingly.
     */
    function _pullUnderlying(
        address token_,
        address from_,
        uint256 quantity_,
        uint256 totalTokenBalance_
    ) internal {
        IBPool optionPool_ = optionPool();
        uint256 weight = optionPool_.getDenormalizedWeight(token_);
        IERC20(token_).safeTransferFrom(from_, address(this), quantity_);
        optionPool_.rebind(token_, totalTokenBalance_.add(quantity_), weight);
        _updateWeights();
    }

    function _mintPoolShare(uint256 quantity) internal {
        _mint(address(this), quantity);
    }

    function _pullPoolShare(address from, uint256 quantity) internal {
        IERC20(address(this)).safeTransferFrom(from, address(this), quantity);
    }

    function _pushPoolShare(address to, uint256 quantity) internal {
        IERC20(address(this)).safeTransfer(to, quantity);
    }

    function _burnPoolShare(uint256 quantity) internal {
        _burn(address(this), quantity);
    }

    // View functions

    function getDenormalizedWeight(address token_) external view returns (uint256) {
        return optionPool().getDenormalizedWeight(token_);
    }

    function getNormalizedWeight(address token_) external view returns (uint256) {
        return optionPool().getNormalizedWeight(token_);
    }

    function getTotalDenormalizedWeight() external view returns (uint256) {
        return optionPool().getTotalDenormalizedWeight();
    }

    function getCurrentTokens() external view returns (address[] memory) {
        return optionPool().getCurrentTokens();
    }

    function getBalance(address token) external view returns (uint256) {
        return optionPool().getBalance(token);
    }

    function getParameters()
        external
        view
        returns (
            uint256 s,
            uint256 k,
            uint256 o,
            uint256 t
        )
    {
        Parameters memory params = parameters;
        s = params.spot;
        k = params.strike;
        o = params.vol;
        t = params.expiry;
    }

    function calcPoolOutGivenSingleIn(
        uint256 tokenBalanceIn,
        uint256 tokenWeightIn,
        uint256 poolSupply,
        uint256 totalWeight,
        uint256 tokenAmountIn,
        uint256 swapFee
    ) external view returns (uint256) {
        return
            optionPool().calcPoolOutGivenSingleIn(
                tokenBalanceIn,
                tokenWeightIn,
                poolSupply,
                totalWeight,
                tokenAmountIn,
                swapFee
            );
    }

    /* function isPublicSwap() external view returns(bool) {
        return optionPool().isPublicSwap();
    } */

    function getSwapFee() external view returns (uint256) {
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
