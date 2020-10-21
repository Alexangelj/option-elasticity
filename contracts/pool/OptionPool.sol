pragma solidity >=0.5.12 <=0.6.2;

/**
 * @title Option AMM
 * @author Primitive
 */

// Primitive
import { ERC20 } from "../tokens/ERC20.sol";
import { IERC20 } from "../tokens/IERC20.sol";
import { IOptionPool } from "./interfaces/IOptionPool.sol";
import { IProxyPriceProvider } from "../oracle/interfaces/IProxyPriceProvider.sol";

// Balancer
import { BNum } from "../libraries/BNum.sol";
import { IBPool } from "./interfaces/IBPool.sol";

// Open Zeppelin
import { Pricing } from "../libraries/Pricing.sol";
import { ReentrancyGuard } from "../utils/ReentrancyGuard.sol";
import { SafeERC20 } from "../libraries/SafeERC20.sol";
import { SafeMath } from "../libraries/SafeMath.sol";

import "@nomiclabs/buidler/console.sol";

contract OptionPool is IOptionPool, ERC20, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event ControllerUpdated(
        address indexed from,
        address indexed oldController,
        address indexed newController
    );
    event TokenBinderUpdated(
        address indexed from,
        address indexed oldTokenBinder,
        address indexed newTokenBinder
    );
    event CalibrationUpdated(
        uint256 beginBlock,
        uint256[] beginWeights,
        uint256 finalBlock,
        uint256[] finalWeights
    );
    event LOG_JOIN(address indexed from, address indexed tokenIn, uint256 tokenAmountIn);
    event LOG_EXIT(address indexed from, address indexed tokenOut, uint256 tokenAmountOut);
    event LOG_SWAP(
        address indexed from,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 tokenAmountIn,
        uint256 tokenAmountOut
    );
    event LOG_WEIGHT_INCREASE(uint256 beginWeight, uint256 updatedWeight, uint256 finalWeight);
    event LOG_WEIGHT_DECREASE(uint256 beginWeight, uint256 updatedWeight, uint256 finalWeight);
    /**
     OptionPool is the core pool which handles token weight and balance logic.
     Controller is a smart contract or EOA which can change the controller -> effectively the admin.
     TokenBinder is responsible for calling the `bind` and `rebind` functions to change the weights of the core pool.
     */
    struct Controllers {
        IBPool optionPool;
        address controller;
        address tokenBinder;
    }

    /**
     These are the option specific parameters which are used to calibrate the core pool.
     Spot: underlying asset spot price (from oracle).
     Strike: the strike price for the option.
     Vol: The implied volatility.
     Expiry: The expiration date of the option.
     */
    struct Parameters {
        uint256 spot;
        uint256 strike;
        uint256 vol;
        uint256 expiry;
    }

    /**
     The asset which the option is on, and an asset that the strike is paid in.
     Should be an asset<>stablecoin pair.
     */
    struct Assets {
        address underlyingToken;
        address quoteToken;
    }

    /**
     The time-sensitive attributes for weight update handling.
     */
    struct Calibration {
        uint256 beginBlock; // Block to begin a weight update.
        uint256 finalBlock; // Block to end a weight update.
        uint256[] beginWeights; // Weight array for tokens to start update from.
        uint256[] finalWeights; // Desired final weights for tokens to end at.
        uint256 lastFee; // The previously set fee to offset the expected next weight change arbitrage.
    }

    // The struct of controlling addresses and core pool.
    Controllers public controllers;

    // The option parameters to calibrate the core pool to.
    Parameters public parameters;

    // The underlying asset of the option and a risk-free (stablecoin) asset.
    Assets public assets;

    // The Primitive oracle aggregation contract to grab any (supported) underlying price.
    IProxyPriceProvider public priceProvider;

    // The weight calibration over time.
    Calibration public calibration;

    uint256 public constant MAX_TOTAL_WEIGHT = 10**18 * 25;
    uint256 public constant MAX_WEIGHT = 10**18 * 25;
    uint256 public constant MIN_WEIGHT = 10**18;

    /* ==== Modifiers ==== */

    modifier onlyController {
        require(msg.sender == controller(), "ERR_NOT_CONTROLLER");
        _;
    }

    modifier onlyBinder {
        require(msg.sender == tokenBinder(), "ERR_NOT_BINDER");
        _;
    }

    modifier canAdjust {
        require(canAdjustToTarget(), "ERR_CANNOT_ADJUST");
        _;
    }

    /* ==== Pseudo Constructor ==== */

    /**
     * @dev Called by a factory immediately after deployment, in the same transaction.
     */
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

        name = name_;
        symbol = symbol_;
        _mintPoolShare(initialSupply);
        _pushPoolShare(msg.sender, initialSupply);
    }

    /* ==== State Changing Functions ===== */

    function setController(address newController) external onlyController nonReentrant {
        emit ControllerUpdated(msg.sender, controllers.controller, newController);
        controllers.controller = newController;
    }

    function setTokenBinder(address newTokenBinder) external onlyBinder nonReentrant {
        emit TokenBinderUpdated(msg.sender, controllers.tokenBinder, newTokenBinder);
        controllers.tokenBinder = newTokenBinder;
    }

    function setSwapFee(uint256 swapFee) external onlyController {
        optionPool().setSwapFee(swapFee);
    }

    /* ==== Weight Business Logic Functions ==== */

    /**
     * @dev Updates Calibration struct storage with a time period and weight target.
     * @param finalWeightsArray An array of uint256 values for denormalized weights to target.
     * @param beginBlock The block which will start the targeting.
     * @param finalBlock The block that will have the weights set to the target weights.
     */
    function targetWeightsOverTime(
        uint256[] calldata finalWeightsArray,
        uint256 beginBlock,
        uint256 finalBlock
    ) public onlyTokenBinder {
        require(finalBlock > beginBlock, "ERR_FINAL_BLOCK_BEFORE");
        IBPool optionPool_ = optionPool();

        // Check final weights array for valid weights and sum.
        uint256 weightsTotalSum = 0;
        address[] memory tokens = optionPool_.getCurrentTokens();
        uint256 tokensLength = tokens.length;
        for (uint256 i = 0; i < tokensLength; i++) {
            _checkValidWeight(finalWeightsArray[i]);
            weightsTotalSum = weightsTotalSum.add(finalWeightsArray[i]);
        }
        require(weightsTotalSum <= MAX_TOTAL_WEIGHT, "ERR_MAX_TOTAL_WEIGHT");
        // Start targeting the final weights at this block if beginBlock has been passed.
        uint256 actualBeginBlock;
        if (block.number > beginBlock) {
            actualBeginBlock = block.number;
        } else {
            actualBeginBlock = beginBlock;
        }
        // Get the current denormalized weights array.
        uint256[] memory beginWeightsArray = new uint256[](tokensLength);
        for (uint256 i = 0; i < tokensLength; i++) {
            beginWeightsArray[i] = optionPool_.getDenormalizedWeight(tokens[i]);
        }
        // Update calibration state with new values.
        _setCalibration(beginWeightsArray, finalWeightsArray, actualBeginBlock, finalBlock);
    }

    /**
     * @dev Internal function to update Calibration struct state with new values.
     * @param beginWeightsArray The denormalized weights to start transitioning away from.
     * @param finalWeightsArray The denormalized weights to start transitioning towards.
     * @param beginBlock The block at the beginning of the weight updates.
     * @param finalBlock The block which will have the final weight change take place.
     */
    function _setCalibration(
        uint256[] memory beginWeightsArray,
        uint256[] memory finalWeightsArray,
        uint256 beginBlock,
        uint256 finalBlock
    ) internal {
        calibration.beginBlock = beginBlock;
        calibration.finalBlock = finalBlock;
        delete calibration.beginWeights; // Clear the beginWeights.
        calibration.beginWeights = beginWeightsArray;
        calibration.finalWeights = finalWeightsArray;
        emit CalibrationUpdated(beginBlock, beginWeightsArray, finalBlock, finalWeightsArray);
    }

    function canAdjustToTarget() public view returns (bool) {
        Calibration memory memCalibration = calibration;
        bool hasTarget = memCalibration.beginBlock != 0;
        bool canUpdateThisBlock = block.number >= memCalibration.beginBlock;
        return hasTarget && canUpdateThisBlock;
    }

    /**
     * @dev Increases the denorm record for the `targetToken` using the state `calibration` finalWeights array.
     * @notice Called on swaps or joining the pool.
     * @param targetToken The token to increase the denormalized weight of.
     * @param newBalance The updated balance of the token to be updated along with the denorm weight.
     */
    function _increaseWeightToTarget(address targetToken, uint256 newBalance) internal canAdjust {
        IBPool optionPool_ = optionPool();
        Calibration memory memCalibration = calibration;

        // Get the index of the target token in the option pool's tokens array.
        address[] memory tokens = optionPool_.getCurrentTokens();
        uint256 tokensLength = tokens.length;
        uint256 targetTokenIndex;
        for (uint256 i = 0; i < tokensLength; i++) {
            if (tokens[i] == targetToken) {
                targetTokenIndex = i;
            }
        }

        // If the final block has passed, use it as the current block rather than the actual current block.
        uint256 currentBlock = block.number > memCalibration.finalBlock
            ? memCalibration.finalBlock
            : block.number;

        // Check to make sure the final weight needs to be increased towards rather than decreased towards.
        if (
            memCalibration.beginWeights[targetTokenIndex] >
            memCalibration.finalWeights[targetTokenIndex]
        ) {
            return;
        }

        // Calculate the weight change based on the number of blocks passed and distance to target weight.
        uint256 updatedWeight = _calculateWeightIncreaseToTarget(
            currentBlock,
            memCalibration.beginBlock,
            memCalibration.finalBlock,
            memCalibration.beginWeights[targetTokenIndex],
            memCalibration.finalWeights[targetTokenIndex]
        );

        // Update the weight using `rebind`.
        optionPool_.rebind(targetToken, optionPool_.getBalance(targetToken), updatedWeight);
        emit LOG_WEIGHT_INCREASE(
            memCalibration.beginWeights[targetTokenIndex],
            updatedWeight,
            memCalibration.finalWeights[targetTokenIndex]
        );
        /* if (currentBlock == memCalibration.finalBlock) {
            calibration.beginBlock = 0; // Setting beginBlock to 0 will cause this function to revert next called.
        } */
    }

    /**
     * @dev Decreases the denorm record for the `targetToken` using the state `calibration` finalWeights array.
     * @notice Called by swaps and when exiting pool.
     * @param targetToken The token to decrease the denormalized weight of.
     * @param newBalance The updated balance of the token to be updated along with the denorm weight.
     */
    function _decreaseWeightToTarget(address targetToken, uint256 newBalance) internal canAdjust {
        IBPool optionPool_ = optionPool();
        Calibration memory memCalibration = calibration;

        // Get the index of the target token in the option pool's tokens array.
        address[] memory tokens = optionPool_.getCurrentTokens();
        uint256 tokensLength = tokens.length;
        uint256 targetTokenIndex;
        for (uint256 i = 0; i < tokensLength; i++) {
            if (tokens[i] == targetToken) {
                targetTokenIndex = i;
            }
        }

        // If the final block has passed, use it as the current block rather than the actual current block.
        uint256 currentBlock = block.number > memCalibration.finalBlock
            ? memCalibration.finalBlock
            : block.number;
        // Check to make sure the final weight needs to be decreased towards rather than increased towards.
        if (
            memCalibration.beginWeights[targetTokenIndex] <
            memCalibration.finalWeights[targetTokenIndex]
        ) {
            return;
        }

        // Calculate the weight change based on the number of blocks passed and distance to target weight.
        uint256 updatedWeight = _calculateWeightDecreaseToTarget(
            currentBlock,
            memCalibration.beginBlock,
            memCalibration.finalBlock,
            memCalibration.beginWeights[targetTokenIndex],
            memCalibration.finalWeights[targetTokenIndex]
        );

        // Update the weight using `rebind`.
        optionPool_.rebind(targetToken, optionPool_.getBalance(targetToken), updatedWeight);
        emit LOG_WEIGHT_DECREASE(
            memCalibration.beginWeights[targetTokenIndex],
            updatedWeight,
            memCalibration.finalWeights[targetTokenIndex]
        );
        /* if (currentBlock == memCalibration.finalBlock) {
            calibration.beginBlock = 0; // Setting beginBlock to 0 will cause this function to revert next called.
        } */
    }

    /**
     * @dev Calculates the desired weight to update to for this block based on block delta and desired total weight delta.
     * @param currentBlock The block which will be used to calculate the distance since last update's block.
     * @param beginBlock The block at the beginning of the weight updates.
     * @param finalBlock The block which will have the final weight change take place.
     * @param beginWeight The denormalized weight at the beginning of weight updates.
     * @param finalWeight The denormalized weight that is desired by the `finalBlock`.
     * @return The denormalized weight to increase to.
     */
    function _calculateWeightIncreaseToTarget(
        uint256 currentBlock,
        uint256 beginBlock,
        uint256 finalBlock,
        uint256 beginWeight,
        uint256 finalWeight
    ) internal pure returns (uint256) {
        uint256 currentBlockDelta = currentBlock.sub(beginBlock);
        uint256 totalBlocks = finalBlock.sub(beginBlock);
        uint256 totalWeightChange = finalWeight.sub(beginWeight);
        uint256 weightChangePerBlock = totalWeightChange.div(totalBlocks);
        uint256 updatedWeight = beginWeight.add(currentBlockDelta.mul(weightChangePerBlock));
        return updatedWeight;
    }

    /**
     * @dev Calculates the desired weight to update to for this block based on block delta and desired total weight delta.
     * @param currentBlock The block which will be used to calculate the distance since last update's block.
     * @param beginBlock The block at the beginning of the weight updates.
     * @param finalBlock The block which will have the final weight change take place.
     * @param beginWeight The denormalized weight at the beginning of weight updates.
     * @param finalWeight The denormalized weight that is desired by the `finalBlock`.
     * @return The denormalized weight to decrease to.
     */
    function _calculateWeightDecreaseToTarget(
        uint256 currentBlock,
        uint256 beginBlock,
        uint256 finalBlock,
        uint256 beginWeight,
        uint256 finalWeight
    ) internal pure returns (uint256) {
        uint256 currentBlockDelta = currentBlock.sub(beginBlock);
        uint256 totalBlocks = finalBlock.sub(beginBlock);
        uint256 totalWeightChange = beginWeight.sub(finalWeight);
        uint256 weightChangePerBlock = totalWeightChange.div(totalBlocks);
        uint256 updatedWeight = beginWeight.sub(currentBlockDelta.mul(weightChangePerBlock));
        return updatedWeight;
    }

    /**
     * @dev Handles logic for updating weights in pool by manipulating token and LP token balances.
     * @notice Requires tokens to be pulled, either pool tokens or LP tokens.
     * @param token_ The address of the token to update the weight for.
     * @param updatedWeight The desired weight to change the current weight for `token_` to.
     */
    /* function updateWeight(address token_, uint256 updatedWeight) external {
        _checkValidWeight(updatedWeight);
        IBPool optionPool_ = optionPool();

        uint256 balance = optionPool_.getBalance(token_);
        uint256 totalWeight = optionPool_.getTotalDenormalizedWeight();
        uint256 weight = optionPool_.getDenormalizedWeight(token_);
        if (updatedWeight < weight) {
            _moveWeightDown(optionPool_, token_, updatedWeight, weight, balance, totalWeight);
        } else {
            _moveWeightUp(optionPool_, token_, updatedWeight, weight, balance, totalWeight);
        }
    } */

    /**
     * @dev Forces a weight change to take place using Calibration to calculate the weightDeltaOverTime.
     */
    /* function adjustWeightsToTargets() external canAdjust {
        IBPool optionPool_ = optionPool();
        Calibration memory memCalibration = calibration;

        uint256 updatedWeight;
        uint256 currentBlock = block.number > memCalibration.finalBlock
            ? memCalibration.finalBlock
            : block.number;

        // Rebind each token with a weight closer to the target weights wrt block time.
        address[] memory tokens = optionPool_.getCurrentTokens();
        uint256 tokensLength = tokens.length;
        for (uint256 i = 0; i < tokensLength; i++) {
            uint256 beginWeight = memCalibration.beginWeights[i];
            uint256 finalWeight = memCalibration.finalWeights[i];
            if (beginWeight >= finalWeight) {
                updatedWeight = _calculateWeightDecreaseToTarget(
                    currentBlock,
                    memCalibration.beginBlock,
                    memCalibration.finalBlock,
                    beginWeight,
                    finalWeight
                );
            } else {
                updatedWeight = _calculateWeightIncreaseToTarget(
                    currentBlock,
                    memCalibration.beginBlock,
                    memCalibration.finalBlock,
                    beginWeight,
                    finalWeight
                );
            }

            optionPool_.rebind(tokens[i], optionPool_.getBalance(tokens[i]), updatedWeight);
        }

        if (currentBlock == memCalibration.finalBlock) {
            calibration.beginBlock = 0; // Setting beginBlock to 0 will cause this function to revert next called.
        }
    } */

    /**
     * @dev Changes weight to updatedWeight by reducing, pushes tokens and burns LP tokens.
     */
    /* function _moveWeightDown(
        IBPool optionPool_,
        address token_,
        uint256 updatedWeight,
        uint256 weight,
        uint256 balance,
        uint256 totalWeight
    ) internal {
        uint256 totalSupply_ = totalSupply;
        require(
            totalWeight.add(weight.sub(updatedWeight)) <= MAX_TOTAL_WEIGHT,
            "ERR_MAX_TOTAL_WEIGHT"
        );

        uint256 absoluteWeightChange = weight.sub(updatedWeight);
        uint256 absoluteBalanceChange = balance.mul(absoluteWeightChange.div(weight));
        uint256 poolAmountIn = totalSupply_.mul(absoluteWeightChange.div(totalWeight));

        require(balance.sub(absoluteBalanceChange) >= 10**5, "ERR_MIN_BALANCE");
        optionPool_.rebind(token_, balance.sub(absoluteBalanceChange), updatedWeight);

        IERC20(token_).safeTransfer(msg.sender, absoluteBalanceChange);
        calibration.beginBlock = 0;
        _burnPoolShare(poolAmountIn);
    } */

    /**
     * @dev Changes weight to updatedWeight by increasing, pulls tokens and mints LP tokens.
     */
    /* function _moveWeightUp(
        IBPool optionPool_,
        address token_,
        uint256 updatedWeight,
        uint256 weight,
        uint256 balance,
        uint256 totalWeight
    ) internal {
        uint256 totalSupply_ = totalSupply;
        require(
            totalWeight.add(weight.sub(updatedWeight)) <= MAX_TOTAL_WEIGHT,
            "ERR_MAX_TOTAL_WEIGHT"
        );

        uint256 absoluteWeightChange = updatedWeight.sub(weight);
        uint256 absoluteBalanceChange = balance.mul(absoluteWeightChange.div(weight));
        uint256 poolAmountOut = totalSupply_.mul(absoluteWeightChange.div(totalWeight));

        IERC20(token_).safeTransferFrom(msg.sender, address(this), absoluteBalanceChange);

        optionPool_.rebind(token_, balance.add(absoluteBalanceChange), updatedWeight);
        calibration.beginBlock = 0;
        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
    } */

    /* ==== Token Binding Functions ==== */

    /**
     * @dev A public function for the tokenBinder entity to call.
     * @param token_ The address of the token to bind to the pool.
     * @param balance The quantity of the token to deposit into the pool.
     * @param denorm The denormalized weight of the token in the pool.
     */
    function bind(
        address token_,
        uint256 balance,
        uint256 denorm
    ) public onlyBinder {
        _bind(token_, balance, denorm);
    }

    /**
     * @dev Adds a token to the pool with a balance and weight.
     * @param token_ The address of the token to bind.
     * @param balance The quantity of token to add to the pool.
     * @param denorm The denormalized weight of the token in the pool.
     */
    function _bind(
        address token_,
        uint256 balance,
        uint256 denorm
    ) internal nonReentrant {
        // Store in memory for gas savings.
        IBPool optionPool_ = optionPool();
        IERC20 token = IERC20(token_);
        // Transfer the `balance` into this contract, then approve it to be pulled by the optionPool.
        token.safeTransferFrom(msg.sender, address(this), balance);
        token.approve(address(optionPool_), uint256(-1));
        // Core pool will pull the `balance` of token from this contract into the pool.
        // Core pool will also make a state change: update the `_records` mapping with a new record.
        optionPool_.bind(token_, balance, denorm);
    }

    /**
     * @dev Updates the weights of a token with a new weight and added balance.
     * @param token_ The address of the token, which will update the mapped record in the core pool.
     * @param balance The quantity of tokens to correlate the denormalized weight to.
     * @param denorm The denormalized weight of the `token_`.
     */
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
        // Forces token record to have a balance equal to the actual token balance of the core pool.
        optionPool_.gulp(token_);
        // Transfer tokens into this contract equal to the difference of `balance` and actual core pool balance.
        uint256 previousBalance = token.balanceOf(address(optionPool_));
        if (balance > previousBalance) {
            token.safeTransferFrom(msg.sender, address(this), balance.sub(previousBalance));
            token.approve(address(optionPool_), uint256(-1));
        }

        // Updates the weight of the `token_`, which will pull in the required tokens necessary to update balance.
        optionPool_.rebind(token_, balance, denorm);
        // If tokens remain in this contract, refund them back to `msg.sender`.
        _pushRemainder(token);
    }

    function unbind(address token_) external onlyBinder nonReentrant {
        // Remove a token from a pool by clearing its record.
        optionPool().unbind(token_);
        _pushRemainder(IERC20(token));
    }

    /* ==== Liquidity Provision Functions ==== */

    /**
     * @dev Mints LP tokens proportional to the deposited pool tokens with respect to total pool tokens.
     * @param poolAmountOut The quantity of LP tokens to be minted.
     * @param maxAmountsIn The highest quantity of pool tokens that can be pulled from `msg.sender`.
     */
    function joinPool(uint256 poolAmountOut, uint256[] calldata maxAmountsIn)
        external
        nonReentrant
    {
        uint256 poolTotal = totalSupply;
        uint256 ratio = BNum.bdiv(poolAmountOut, poolTotal); // Proportion of LP token / total LP tokens
        require(ratio != 0, "ERR_MATH_APPROX");

        IBPool optionPool_ = optionPool();
        address[] memory tokens = optionPool_.getCurrentTokens();
        uint256 tokensLength = tokens.length;
        // Pull pool tokens that are needed to mint the desired amount of LP tokens.
        for (uint256 i = 0; i < tokensLength; i++) {
            address t = tokens[i];
            uint256 bal = optionPool_.getBalance(t);
            uint256 tokenAmountIn = BNum.bmul(ratio, bal);
            require(tokenAmountIn != 0, "ERR_MATH_APPROX");
            require(tokenAmountIn <= maxAmountsIn[i], "ERR_LIMIT_IN");
            if (calibration.beginBlock != 0 && block.number > calibration.beginBlock) {
                _increaseWeightToTarget(t, bal.add(tokenAmountIn));
            }
            emit LOG_JOIN(msg.sender, t, tokenAmountIn);
            _pullUnderlying(t, msg.sender, tokenAmountIn, bal);
        }
        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
    }

    /**
     * @dev Unwraps LP tokens for their proportional claim on the pool's tokens.
     * @param poolAmountIn The quantity of LP tokens to unwrap.
     * @param minAmountsOut The minimum quantity of pool tokens to receive in exchange for LP tokens unwrapped.
     */
    function exitPool(uint256 poolAmountIn, uint256[] calldata minAmountsOut)
        external
        nonReentrant
    {
        uint256 poolTotal = totalSupply;
        uint256 ratio = BNum.bdiv(poolAmountIn, poolTotal); // Proportion of LP token / total LP tokens
        require(ratio != 0, "ERR_MATH_APPROX");

        _pullPoolShare(msg.sender, poolAmountIn); // Transfer LP tokens into this contract.
        _burnPoolShare(poolAmountIn); // Burn LP tokens from this contract.

        IBPool optionPool_ = optionPool();
        address[] memory tokens = optionPool_.getCurrentTokens();
        uint256 tokensLength = tokens.length;
        // Push pool tokens out to `msg.sender` as long as they are above min. tokens desired.
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

    /* ==== Pool Single Token Entry and Exit Functions ==== */

    /**
     * @dev Mints LP tokens by depositing a single token.
     * @param tokenIn The address of the token to deposit into the core pool.
     * @param tokenAmountIn The quantity of the token to deposit into the core pool.
     * @param minPoolAmountOut The minimum quantity of LP tokens to mint. Revert if less than.
     */
    function joinswapExternAmountIn(
        address tokenIn,
        uint256 tokenAmountIn,
        uint256 minPoolAmountOut
    ) external nonReentrant returns (uint256 poolAmountOut) {
        IBPool optionPool_ = optionPool();
        // Fail early if token is not one of the bound pool tokens.
        require(optionPool_.isBound(tokenIn), "ERR_NOT_BOUND");

        // Calculates the quantity of LP tokens to mint based on a single token deposit.
        poolAmountOut = optionPool_.calcPoolOutGivenSingleIn(
            optionPool_.getBalance(tokenIn),
            optionPool_.getDenormalizedWeight(tokenIn),
            totalSupply,
            optionPool_.getTotalDenormalizedWeight(),
            tokenAmountIn,
            optionPool_.getSwapFee()
        );
        require(poolAmountOut >= minPoolAmountOut, "ERR_LIMIT_OUT");

        if (calibration.beginBlock != 0 && block.number > calibration.beginBlock) {
            _increaseWeightToTarget(tokenIn, optionPool_.getBalance(tokenIn).add(tokenAmountIn));
        }

        // Mint the LP tokens and transfer them out to the `msg.sender`.
        emit LOG_JOIN(msg.sender, tokenIn, tokenAmountIn);
        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);

        // Pull the `tokenIn` from the `msg.sender` into the core pool.
        // Warning: updates state of the core pool with a call to update weights.
        uint256 totalBalance = optionPool_.getBalance(tokenIn);
        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn, totalBalance);
        return poolAmountOut;
    }

    /* ==== Swap Functions ==== */

    function swapExactAmountIn(
        address tokenIn,
        uint256 tokenAmountIn,
        address tokenOut,
        uint256 minAmountOut,
        uint256 maxPrice
    ) external nonReentrant returns (uint256 tokenAmountOut, uint256 spotPriceAfter) {
        IBPool optionPool_ = optionPool();
        // Fail early if token is not one of the bound pool tokens.
        require(optionPool_.isBound(tokenIn), "ERR_NOT_BOUND");

        uint256 tokenInBalance = optionPool_.getBalance(tokenIn);
        uint256 tokenOutBalance = optionPool_.getBalance(tokenOut);
        uint256 spotPriceBefore;

        require(tokenAmountIn <= tokenInBalance.mul(10**9), "ERR_MAX_IN_RATIO");
        {
            //uint256 tokenInWeight = optionPool_.getDenormalizedWeight(tokenIn);
            //uint256 tokenOutWeight = optionPool_.getDenormalizedWeight(tokenOut);
            spotPriceBefore = optionPool_.calcSpotPrice(
                tokenInBalance,
                optionPool_.getDenormalizedWeight(tokenIn),
                tokenOutBalance,
                optionPool_.getDenormalizedWeight(tokenOut),
                optionPool_.getSwapFee()
            );
            //console.log(spotPriceBefore);
            require(spotPriceBefore <= maxPrice, "ERR_BAD_LIMIT_PRICE");

            tokenAmountOut = optionPool_.calcOutGivenIn(
                tokenInBalance,
                optionPool_.getDenormalizedWeight(tokenIn),
                tokenOutBalance,
                optionPool_.getDenormalizedWeight(tokenOut),
                tokenAmountIn,
                optionPool_.getSwapFee()
            );
            require(tokenAmountOut >= minAmountOut, "ERR_LIMIT_OUT");
        }

        // Pull the `tokenIn` from the `msg.sender` into the core pool.
        // Warning: updates state of the core pool with a call to update weights.
        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn, tokenInBalance);
        _pushUnderlying(tokenOut, msg.sender, tokenAmountOut, tokenOutBalance);

        // Update actual denorm weight records.
        //console.log(calibration.beginBlock, block.number);
        if (calibration.beginBlock != 0 && block.number > calibration.beginBlock) {
            //console.log("increasing weight!");
            _increaseWeightToTarget(tokenIn, tokenInBalance.add(tokenAmountIn));
            _decreaseWeightToTarget(tokenOut, tokenOutBalance.sub(tokenAmountOut));
        }

        spotPriceAfter = optionPool_.calcSpotPrice(
            tokenInBalance.add(tokenAmountIn),
            optionPool_.getDenormalizedWeight(tokenIn),
            tokenOutBalance.add(tokenAmountOut),
            optionPool_.getDenormalizedWeight(tokenOut),
            optionPool_.getSwapFee()
        );

        //require(spotPriceAfter >= spotPriceBefore, "ERR_MATH_APPROX"); // FIX -> small swaps reduce spot price
        require(spotPriceAfter <= maxPrice, "ERR_LIMIT_PRICE");
        //console.log(spotPriceBefore, tokenAmountIn, tokenAmountOut, "ERR_MAX_APPROX");
        require(
            spotPriceBefore <= tokenAmountIn.mul(1 ether).div(tokenAmountOut),
            "ERR_MATH_APPROX"
        );

        emit LOG_SWAP(msg.sender, tokenIn, tokenOut, tokenAmountIn, tokenAmountOut);

        return (tokenAmountOut, spotPriceAfter);
    }

    /* ==== Token Balance Transfer Functions ==== */

    function _pushUnderlying(
        address token,
        address to,
        uint256 quantity,
        uint256 totalTokenBalance
    ) internal {
        IBPool optionPool_ = optionPool();
        uint256 beginBlock = calibration.beginBlock;
        uint256 weight = optionPool_.getDenormalizedWeight(token);
        //console.log(beginBlock, block.number);

        optionPool_.rebind(token, totalTokenBalance.sub(quantity), weight);
        IERC20(token).safeTransfer(to, quantity);
        /* if (beginBlock != 0 && block.number > beginBlock) {
            _decreaseWeightToTarget(token, totalTokenBalance.sub(quantity));
        } */
    }

    /**
     * @dev Safe Transfer From assets and rebind the pool accordingly.
     */
    function _pullUnderlying(
        address token,
        address from,
        uint256 quantity,
        uint256 totalTokenBalance
    ) internal {
        IBPool optionPool_ = optionPool();
        uint256 weight = optionPool_.getDenormalizedWeight(token);
        IERC20(token).safeTransferFrom(from, address(this), quantity);
        uint256 beginBlock = calibration.beginBlock;
        //console.log(beginBlock, block.number);
        optionPool_.rebind(token, totalTokenBalance.add(quantity), weight);
        /* if (beginBlock != 0 && block.number > beginBlock) {
            _increaseWeightToTarget(token, totalTokenBalance.add(quantity));
        } */
    }

    /**
     * @dev Internal function to transfer out remaining `token` balance to `msg.sender`.
     * @param token The ERC20 token to check this contract's balance of and transfer out.
     */
    function _pushRemainder(IERC20 token) internal {
        uint256 tokenBalance = token.balanceOf(address(this));
        if (tokenBalance > 0) {
            token.safeTransfer(msg.sender, tokenBalance);
        }
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

    /* ==== Internal Functions ==== */

    /**
     * @dev Internal function that reverts if a weight is out of bounds.
     */
    function _checkValidWeight(uint256 weight) internal pure {
        require(weight <= MAX_WEIGHT, "ERR_MAX_WEIGHT");
        require(weight >= MIN_WEIGHT, "ERR_MIN_WEIGHT");
    }

    /* ==== View Functions ==== */

    function calcSpotPrice(address tokenIn, address tokenOut) external view returns (uint256) {
        IBPool optionPool_ = optionPool();
        uint256 spot = optionPool_.calcSpotPrice(
            optionPool_.getBalance(tokenIn),
            optionPool_.getDenormalizedWeight(tokenIn),
            optionPool_.getBalance(tokenOut),
            optionPool_.getDenormalizedWeight(tokenOut),
            optionPool_.getSwapFee()
        );

        return spot;
    }

    function calcSingleOutGivenPoolIn(address tokenOut, uint256 poolAmountIn)
        external
        view
        returns (uint256)
    {
        IBPool optionPool_ = optionPool();
        uint256 tokenAmountOut = optionPool_.calcSingleOutGivenPoolIn(
            optionPool_.getBalance(tokenOut),
            optionPool_.getDenormalizedWeight(tokenOut),
            totalSupply,
            optionPool_.getTotalDenormalizedWeight(),
            poolAmountIn,
            optionPool_.getSwapFee()
        );

        return tokenAmountOut;
    }

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

    function getFinalWeights() public view returns (uint256[] memory) {
        return calibration.finalWeights;
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

    function getExitFee() external view returns (uint256) {
        return 0;
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
