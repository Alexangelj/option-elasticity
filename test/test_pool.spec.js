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

const logEvent = async (contract, name) => {
    contract.on(name, (...args) => {
        let receipt = args[args.length - 1];
        let length = receipt.args.length;
        let array = receipt.args;
        let keys = Object.keys(array);
        //console.log(`${name} ${array} ${receipt}`);
        /* keys.map((v) => {
            return console.log(`${name} ${v}: ${array[v]}`);
        }); */
        /* for (let i = 0; i < args.length - 1; i++) {
            let value = args[i];
            if (ethers.BigNumber.isBigNumber(value)) {
                console.log(`${name} ${formatEther(value)}`);
            } else {
                console.log(`${name} ${value}`);
            }
        } */
    });
};

const calcSingleOutGivenPoolIn = async (pool, tokenOut, poolAmountIn) => {
    let poolSupply = await pool.totalSupply();
    if (poolSupply > 0 && poolSupply > poolAmountIn) {
        let amoutOut = await pool.calcSingleOutGivenPoolIn(tokenOut, poolAmountIn);
        return amoutOut;
    } else {
        return 0;
    }
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

/**
 * function extrapolatePoolValueFromToken()
        external
        view
        returns (address tokenAddress, uint256 extrapolatedValue)
    {
        IBPool optionPool_ = optionPool();
        uint256 totalWeight = optionPool_.getTotalDenormalizedWeight();
        address[] memory tokens = optionPool_.getCurrentTokens();
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            tokenAddress = tokens[i];
            uint256 bal = optionPool_.getBalance(tokenAddress);
            uint256 denorm = optionPool_.getDenormalizedWeight(tokenAddress);
            extrapolatedValue = bal.mul(totalWeight.mul(1 ether).div(denorm));
            break;
        }
        require(extrapolatedValue > 0, "ERR_NONE_READY");
    }
 */

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
            console.log(formatEther(calibration.weights[0]), formatEther(calibration.weights[1]));
            await pool.bind(ETHER.address, calibration.amounts[0], calibration.weights[0].mul(25));
            await pool.bind(DAI.address, calibration.amounts[1], calibration.weights[1].mul(25));
        });
    });

    describe("targetWeightsOverTime", () => {
        afterEach(async () => {
            await generateReport();
        });

        it("should set calibration with a new target weights array", async () => {
            // Set a new spot price then calc a new calibration.
            await oracle.setTestPrice(parseEther("101"));
            calibration = new Calibration(CONFIG, ETHER, DAI);
            await calibration.initialize(pricing, oracle, pool);

            // Use the new calibration weights for the target weights.
            let finalWeightsArray = [
                calibration.weights[0].mul(25),
                calibration.weights[1].mul(25),
            ];
            let provider = new ethers.providers.JsonRpcProvider();
            let beginBlock = await provider.send("eth_blockNumber");
            let finalBlock = beginBlock + 2;
            await expect(
                pool.targetWeightsOverTime(finalWeightsArray, beginBlock, finalBlock)
            ).to.emit(pool, "CalibrationUpdated");
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
            let minAmountOut = 0;
            let maxPrice = parseEther("50000");
            await expect(
                pool.swapExactAmountIn(tokenIn, tokenAmountIn, tokenOut, minAmountOut, maxPrice)
            ).to.emit(pool, "LOG_SWAP");
        });

        it("should swap tokenIn for tokenOut after some blocks have passed", async () => {
            let provider = new ethers.providers.JsonRpcProvider();
            await provider.send("evm_mine");
            let tokenIn = ETHER.address;
            let tokenAmountIn = parseEther("5");
            let tokenOut = DAI.address;
            let minAmountOut = 0;
            let maxPrice = parseEther("50000");
            await expect(
                pool.swapExactAmountIn(tokenIn, tokenAmountIn, tokenOut, minAmountOut, maxPrice)
            ).to.emit(pool, "LOG_SWAP");
        });

        it("should swap a small quantity of tokens", async () => {
            let provider = new ethers.providers.JsonRpcProvider();
            await provider.send("evm_mine");
            let tokenIn = ETHER.address;
            let tokenAmountIn = parseEther("0.0001");
            let tokenOut = DAI.address;
            let minAmountOut = 0;
            let maxPrice = parseEther("50000");
            /* pool.on("LOG_SWAP", (caller, tokenIn, tokenOut, tokenAmountIn, tokenAmountOut) => {
                tokenAmountIn = formatEther(tokenAmountIn);
                tokenAmountOut = formatEther(tokenAmountOut);
                console.log("LOG_SWAP: ", {
                    caller,
                    tokenIn,
                    tokenOut,
                    tokenAmountIn,
                    tokenAmountOut,
                });
            });

            pool.on("LOG_WEIGHT_INCREASE", (beginWeight, updatedWeight, finalWeight) => {
                weightChange = formatEther(updatedWeight.sub(beginWeight).div(25));
                beginWeight = formatEther(beginWeight.div(25));
                updatedWeight = formatEther(updatedWeight.div(25));
                finalWeight = formatEther(finalWeight.div(25));

                console.log("LOG_WEIGHT_INCREASE: ", {
                    beginWeight,
                    updatedWeight,
                    finalWeight,
                    weightChange,
                });
            }); */

            /* pool.on("LOG_WEIGHT_DECREASE", (beginWeight, updatedWeight, finalWeight) => {
                weightChange = formatEther(updatedWeight.sub(beginWeight).div(25));
                beginWeight = formatEther(beginWeight.div(25));
                updatedWeight = formatEther(updatedWeight.div(25));
                finalWeight = formatEther(finalWeight.div(25));
                console.log("LOG_WEIGHT_DECREASE: ", {
                    beginWeight,
                    updatedWeight,
                    finalWeight,
                    weightChange,
                });
            }); */

            //logEvent(pool, "LOG_WEIGHT_DECREASE");
            await expect(
                pool.swapExactAmountIn(tokenIn, tokenAmountIn, tokenOut, minAmountOut, maxPrice)
            ).to.emit(pool, "LOG_SWAP");
        });
    });

    describe("simulate", () => {
        afterEach(async () => {
            await generateReport();
        });

        it("update spot price by $1, call a swap, log results", async () => {
            let times = 25;
            let one = parseEther("1");
            let tokenIn = ETHER.address;
            let tokenAmountIn = parseEther("1");
            let tokenOut = DAI.address;
            let minAmountOut = 0;
            let maxPrice = parseEther("50000");

            for (let i = 0; i < times; i++) {
                // update oracle by $1
                let spot = await oracle.testPrice();
                await oracle.setTestPrice(spot.add(one));

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

                // mine a block
                let provider = new ethers.providers.JsonRpcProvider();
                await provider.send("evm_mine");

                // log the results
                let lpTokenValue = await calcLpTokenValue(pool);
                spot = await oracle.testPrice();
                let putPrice = await pricing.getPutPrice(
                    spot,
                    CONFIG.strike,
                    CONFIG.volatility,
                    CONFIG.time
                );

                console.log(
                    `Spot: ${formatEther(spot)}, lpTokenValue: ${formatEther(
                        lpTokenValue
                    )}, putPrice: ${formatEther(putPrice)}`
                );
            }
        });
    });
});
