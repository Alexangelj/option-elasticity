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

const calcLpTokenValue = async (pool, oracle, dai, poolAmountIn) => {
    let amounts = await calcExitPoolAmountsOut(pool, poolAmountIn);
    let spot = await oracle.testPrice();
    let value = ethers.BigNumber.from(0);

    for (let i = 0; i < Object.keys(amounts).length; i++) {
        let amount = amounts[dai];
        if (dai == Object.keys(amounts)[i]) {
            amount = amount;
        } else {
            amount = amount.mul(spot).div(parseEther("1"));
        }

        value = value.add(amount);
    }

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
        let lpValue = await calcLpTokenValue(pool, oracle, DAI.address, parseEther("1"));
        let totalSupply = await pool.totalSupply();
        Object.assign(data, {
            elasticity: calibration.elasticity,
            callPrice: calibration.callPrice,
            putPrice: calibration.putPrice,
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
        await pool.setSwapFee(parseEther("0.1")); // 10^15 instead of 10^12 = min_fee
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

        it("should join the pool and mint 100000 LP tokens", async () => {
            let poolAmountOut = parseEther("100000");
            let maxAmountsIn = [parseEther("1000000"), parseEther("1000000")];
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
            let tokenAmountIn = 100000000000;
            let tokenOut = DAI.address;
            let minAmountOut = 0;
            let maxPrice = parseEther("50000");
            pool.on("LOG_SWAP", (caller, tokenIn, tokenOut, tokenAmountIn, tokenAmountOut) => {
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
            });

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

            logEvent(pool, "LOG_WEIGHT_DECREASE");
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
            let poolAmountOut = parseEther("100");
            let maxAmountsIn = [parseEther("1000000"), parseEther("1000000")];
            await expect(pool.joinPool(poolAmountOut, maxAmountsIn)).to.emit(pool, "LOG_JOIN");
        });
    });
});
