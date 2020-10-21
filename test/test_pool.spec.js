const bre = require("@nomiclabs/buidler");
const chai = require("chai");
const { assert, expect } = chai;
const { solidity } = require("ethereum-waffle");
chai.use(solidity);
const { formatEther, parseEther } = bre.ethers.utils;
const setup = require("./lib/setup");
const { Token, Calibration } = require("./lib/entities");
const deployOptionFactory = require("./lib/utils/deployOptionFactory");
const deployOptionPool = require("./lib/utils/deployOptionPool");
const deployOptionController = require("./lib/utils/deployOptionController");
const CONFIG = require("./lib/config");
const BalanceTable = require("./lib/logs/balanceTable");
const formatTableData = require("./lib/logs/formatTableData");
const table = new BalanceTable({});

const calcSingleOutGivenPoolIn = async (pool, tokenOut, poolAmountIn) => {
    let poolSupply = await pool.totalSupply();
    if (poolSupply > 0 && poolSupply > poolAmountIn) {
        let amoutOut = await pool.calcSingleOutGivenPoolIn(tokenOut, poolAmountIn);
        return amoutOut;
    } else {
        return 0;
    }
};

const getCurrentTokens = async (pool) => {
    let tokens = await pool.getCurrentTokens();
    return tokens;
};

const calcSpotPrice = async (pool, tokenIn, tokenOut) => {
    let spot = await pool.calcSpotPrice(tokenIn, tokenOut);
    return spot;
};

const calcOutGivenIn = async (pool, tokenAmountIn, tokenIn, tokenOut) => {
    let tokenAmountOut = await pool.calcOutGivenIn(tokenAmountIn, tokenIn, tokenOut);
    return tokenAmountOut;
};

const calcExitPoolAmountsOut = async (pool, poolAmountIn) => {
    let poolTotal = await pool.totalSupply();
    let EXIT_FEE = await pool.getExitFee();
    let exitFee = poolAmountIn.mul(EXIT_FEE);
    let pAiAfterExitFee = poolAmountIn.sub(exitFee);
    let ratio = pAiAfterExitFee.mul(parseEther("1")).div(poolTotal);
    let tokens = await pool.getCurrentTokens();
    let amounts = {};

    for (let i = 0; i < tokens.length; i++) {
        let t = tokens[i];
        let bal = await pool.getBalance(t);
        let tokenAmountOut = ratio.mul(parseEther("1")).div(bal);
        amounts[t] = tokenAmountOut;
    }

    return amounts;
};

const calcLpTokenValue = async (pool) => {
    let one = parseEther("1");
    let totalWeight = await pool.getTotalDenormalizedWeight();
    let tokens = await pool.getCurrentTokens();
    let token = tokens[1]; //dai
    let bal = await pool.getBalance(token);
    let denorm = await pool.getDenormalizedWeight(token);
    let extrapolated = bal.mul(totalWeight.mul(one).div(denorm)).div(one);
    let totalSupply = await pool.totalSupply();
    let value = extrapolated.mul(one).div(totalSupply);
    return value;
};

describe("OptionPool.sol", () => {
    let signers, Admin, Alice;
    let pool, ETHER, DAI;
    let pricing, oracle;

    const generateReport = async () => {
        let data = await formatTableData(
            [CONFIG.name],
            [pool],
            [ETHER.contract, DAI.contract, pool],
            [Alice]
        );
        let spot = await oracle.testPrice();
        let lpTokenValue = await calcSingleOutGivenPoolIn(pool, DAI.address, parseEther("1"));
        if (lpTokenValue > 0) lpTokenValue = lpTokenValue.mul(spot).div(parseEther("1"));
        let lpValue = await calcLpTokenValue(pool);
        let totalSupply = await pool.totalSupply();
        let putPrice = await pricing.getPutPrice(
            spot,
            CONFIG.strike,
            CONFIG.volatility,
            CONFIG.time
        );
        Object.assign(data, {
            elasticity: calibration.elasticity,
            callPrice: calibration.callPrice,
            putPrice: putPrice,
            actualSpot: spot,
            lpTokenValue: lpValue,
            totalSupply: totalSupply,
        });
        table.generate(data);
    };

    before(async () => {
        // Get signers.
        signers = await ethers.getSigners();
        Admin = signers[0];
        Alice = Admin._address;
        // Standard erc20s with mint functions.
        ETHER = new Token("Ethereum", "ETH", parseEther("100000000"));
        DAI = new Token("Dai Stablecoin", "DAI", parseEther("100000000"));
        await ETHER.deploy();
        await DAI.deploy();
        // Contracts needed to test and setup test environment.
        contractsToDeploy = ["Pricing", "ProxyPriceProvider"];
        [pricing, oracle] = await setup.deployContracts(contractsToDeploy);
        // Setup oracle with a test price.
        await oracle.setTestPrice(parseEther("100"));
        // Deploy core pool factory, option controller, and option pool.
        optionFactory = await deployOptionFactory(Admin);
        controller = await deployOptionController(optionFactory, ETHER, DAI);
        pool = await deployOptionPool(controller, oracle, ETHER, DAI);
        // Create a new calibration instance.
        calibration = new Calibration(CONFIG, ETHER, DAI);
        await calibration.initialize(pricing, oracle, pool);

        // Set the swap fee a little higher
        await pool.setSwapFee(parseEther("0.025")); // 10^15 instead of 10^12 = min_fee
    });

    describe("bind", () => {
        afterEach(async () => {
            await generateReport();
        });

        it("should bind initial tokens, with initial weights and amounts", async () => {
            let token0 = ETHER.address;
            let balance0 = calibration.amounts[0];
            let weight0 = calibration.weights[0].mul(25);
            let token1 = DAI.address;
            let balance1 = calibration.amounts[1];
            let weight1 = calibration.weights[1].mul(25);
            await expect(pool.bind(token0, balance0, weight0))
                .to.emit(pool, "PoolBoundTokenUpdate")
                .withArgs(Alice, token0, balance0, weight0);
            await expect(pool.bind(token1, balance1, weight1))
                .to.emit(pool, "PoolBoundTokenUpdate")
                .withArgs(Alice, token1, balance1, weight1);
        });
    });

    describe("targetWeightsOverTime", () => {
        afterEach(async () => {
            await generateReport();
        });

        it("should set calibration with a new target weights array", async () => {
            // Get the beginning weights to check later.
            let tokens = await pool.getCurrentTokens();
            let beginWeightsArray = [];
            for (let i = 0; i < tokens.length; i++) {
                beginWeightsArray[i] = await pool.getDenormalizedWeight(tokens[i]);
            }

            // Set a new spot price then calc a new calibration.
            await oracle.setTestPrice(parseEther("101"));
            calibration = new Calibration(CONFIG, ETHER, DAI);
            await calibration.initialize(pricing, oracle, pool);

            // Use the new calibration weights for the target weights.
            let finalWeightsArray = [
                calibration.weights[0].mul(25),
                calibration.weights[1].mul(25),
            ];
            let beginBlock = await ethers.provider.getBlockNumber();
            let finalBlock = beginBlock + CONFIG.updatePeriodInBlocks;
            await expect(pool.targetWeightsOverTime(finalWeightsArray, beginBlock, finalBlock))
                .to.emit(pool, "CalibrationUpdated")
                .withArgs(beginBlock, beginWeightsArray, finalBlock, finalWeightsArray);
        });
    });

    describe("joinPool", () => {
        afterEach(async () => {
            await generateReport();
        });

        it("should join the pool and mint starting LP tokens", async () => {
            let token0Value = parseEther("250"); // ether
            let token1Value = parseEther("50000"); // dai
            let poolAmountOut = parseEther("490");
            let maxAmountsIn = [token0Value, token1Value];
            await expect(pool.joinPool(poolAmountOut, maxAmountsIn)).to.emit(pool, "LOG_JOIN");
        });
    });

    describe("swapExactAmountIn", () => {
        afterEach(async () => {
            await generateReport();
        });

        it("should swap tokenIn for tokenOut", async () => {
            let tokenIn = ETHER.address;
            let tokenAmountIn = parseEther("5");
            let tokenOut = DAI.address;
            let minAmountOut = await calcOutGivenIn(pool, tokenAmountIn, tokenIn, tokenOut);
            let spotPrice = await calcSpotPrice(pool, tokenIn, tokenOut);
            let slippage = spotPrice.div(CONFIG.slippage);
            let maxPrice = spotPrice.add(slippage);
            await expect(
                pool.swapExactAmountIn(tokenIn, tokenAmountIn, tokenOut, minAmountOut, maxPrice)
            )
                .to.emit(pool, "LOG_SWAP")
                .withArgs(Alice, tokenIn, tokenOut, tokenAmountIn, minAmountOut);
        });

        it("should swap tokenIn for tokenOut after a block has passed", async () => {
            await ethers.provider.send("evm_mine");
            let tokenIn = ETHER.address;
            let tokenAmountIn = parseEther("5");
            let tokenOut = DAI.address;
            let minAmountOut = await calcOutGivenIn(pool, tokenAmountIn, tokenIn, tokenOut);
            let spotPrice = await calcSpotPrice(pool, tokenIn, tokenOut);
            let slippage = spotPrice.div(CONFIG.slippage);
            let maxPrice = spotPrice.add(slippage);
            await expect(
                pool.swapExactAmountIn(tokenIn, tokenAmountIn, tokenOut, minAmountOut, maxPrice)
            )
                .to.emit(pool, "LOG_SWAP")
                .withArgs(Alice, tokenIn, tokenOut, tokenAmountIn, minAmountOut);
        });

        it("should swap a small quantity of tokens", async () => {
            await ethers.provider.send("evm_mine");
            let tokenIn = ETHER.address;
            let tokenAmountIn = parseEther("0.0001");
            let tokenOut = DAI.address;
            let minAmountOut = await calcOutGivenIn(pool, tokenAmountIn, tokenIn, tokenOut);
            let spotPrice = await calcSpotPrice(pool, tokenIn, tokenOut);
            let slippage = spotPrice.mul(parseEther("1")).div(CONFIG.slippage);
            let maxPrice = spotPrice.add(slippage);
            await expect(
                pool.swapExactAmountIn(tokenIn, tokenAmountIn, tokenOut, minAmountOut, maxPrice)
            )
                .to.emit(pool, "LOG_SWAP")
                .withArgs(Alice, tokenIn, tokenOut, tokenAmountIn, minAmountOut);
        });
    });

    describe("simulate", () => {
        afterEach(async () => {
            await generateReport();
        });

        it("update spot price by $1, call a swap, log results", async () => {
            console.log("This tests take a little while to mine blocks...");
            let times = 25;
            let one = parseEther("1");
            let tokenIn = ETHER.address;
            let tokenAmountIn = parseEther("0.1");
            let tokenOut = DAI.address;
            let minAmountOut = 0;
            let maxPrice = parseEther("50000");
            await oracle.setTestPrice(parseEther("100"));

            let blocksAnHour = 4 * 60;

            for (let i = 0; i < times; i++) {
                // update oracle by $1
                let spot = await oracle.testPrice();
                await oracle.setTestPrice(spot.add(one));

                // calibrate new elasticity since spot increased
                calibration = new Calibration(CONFIG, ETHER, DAI);
                await calibration.initialize(pricing, oracle, pool);

                // Use the new calibration weights for the target weights.
                let finalWeightsArray = [
                    calibration.weights[0].mul(25),
                    calibration.weights[1].mul(25),
                ];
                let beginBlock = await ethers.provider.getBlockNumber();
                let finalBlock = +beginBlock + blocksAnHour;
                await expect(
                    pool.targetWeightsOverTime(finalWeightsArray, beginBlock, finalBlock)
                ).to.emit(pool, "CalibrationUpdated");

                // mine some blocks
                let blocksToMine = blocksAnHour - 1;
                for (let i = 0; i < blocksToMine; i++) {
                    await ethers.provider.send("evm_mine");
                }
                let block = await ethers.provider.getBlockNumber();

                // swap 1 ether
                await expect(
                    pool.swapExactAmountIn(
                        tokenIn,
                        tokenAmountIn,
                        tokenOut,
                        minAmountOut,
                        maxPrice
                    )
                ).to.emit(pool, "LOG_SWAP");

                // log the results
                let lpTokenValue = await calcLpTokenValue(pool);
                spot = await oracle.testPrice();
                let putPrice = await pricing.getPutPrice(
                    spot,
                    CONFIG.strike,
                    CONFIG.volatility,
                    CONFIG.time
                );
                let actualWeights = [];
                let tokens = await pool.getCurrentTokens();
                for (let i = 0; i < tokens.length; i++) {
                    let weight = await pool.getDenormalizedWeight(tokens[i]);
                    actualWeights.push(weight);
                }

                let poolSpot = await pool.calcSpotPrice(tokens[1], tokens[0]); // the spot price is reversed?

                /* console.log(
                    `Block: ${block.toString()}, Spot: ${formatEther(
                        spot
                    )}, pool spot: ${formatEther(poolSpot)}, lpTokenValue: ${formatEther(
                        lpTokenValue
                    )}, putPrice: ${formatEther(putPrice)}, weights: ${finalWeightsArray.map((v) =>
                        formatEther(v.div(25))
                    )}, actualWeights: ${actualWeights.map((v) => formatEther(v.div(25)))}`
                ); */
            }
        });

        /* it("update spot price by $1, call a join, log results", async () => {
            let times = 25;
            let one = parseEther("1");
            await oracle.setTestPrice(parseEther("100"));

            let blocksAnHour = 4 * 60;

            for (let i = 0; i < times; i++) {
                // update oracle by $1
                let spot = await oracle.testPrice();
                await oracle.setTestPrice(spot.add(one));

                // calibrate new elasticity since spot increased
                calibration = new Calibration(CONFIG, ETHER, DAI);
                await calibration.initialize(pricing, oracle, pool);

                // Use the new calibration weights for the target weights.
                let finalWeightsArray = [
                    calibration.weights[0].mul(25),
                    calibration.weights[1].mul(25),
                ];
                let beginBlock = await ethers.provider.getBlockNumber();
                let finalBlock = +beginBlock + blocksAnHour;
                await expect(
                    pool.targetWeightsOverTime(finalWeightsArray, beginBlock, finalBlock)
                ).to.emit(pool, "CalibrationUpdated");

                // mine some blocks
                let blocksToMine = blocksAnHour - 1;
                for (let i = 0; i < blocksToMine; i++) {
                    await ethers.provider.send("evm_mine");
                }
                let block = await ethers.provider.getBlockNumber();

                let token0Value = parseEther("2500"); // ether
                let token1Value = parseEther("50000"); // dai
                let poolAmountOut = parseEther("1");
                let maxAmountsIn = [token0Value, token1Value];
                await expect(pool.joinPool(poolAmountOut, maxAmountsIn)).to.emit(pool, "LOG_JOIN");

                // log the results
                let lpTokenValue = await calcLpTokenValue(pool);
                spot = await oracle.testPrice();
                let putPrice = await pricing.getPutPrice(
                    spot,
                    CONFIG.strike,
                    CONFIG.volatility,
                    CONFIG.time
                );
                let actualWeights = [];
                let tokens = await pool.getCurrentTokens();
                for (let i = 0; i < tokens.length; i++) {
                    let weight = await pool.getDenormalizedWeight(tokens[i]);
                    actualWeights.push(weight);
                }

                let poolSpot = await pool.calcSpotPrice(tokens[1], tokens[0]); // the spot price is reversed?

                console.log(
                    `Block: ${block.toString()}, Spot: ${formatEther(
                        spot
                    )}, pool spot: ${formatEther(poolSpot)}, lpTokenValue: ${formatEther(
                        lpTokenValue
                    )}, putPrice: ${formatEther(putPrice)}, weights: ${finalWeightsArray.map((v) =>
                        formatEther(v.div(25))
                    )}, actualWeights: ${actualWeights.map((v) => formatEther(v.div(25)))}`
                );
            }
        }); */
    });
});
