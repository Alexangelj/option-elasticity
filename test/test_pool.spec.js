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

describe("OptionPool.sol", () => {
    const generateReport = async () => {
        let data = await formatTableData([CONFIG.name], [pool], [ETHER.contract, DAI.contract]);
        Object.assign(data, {
            elasticity: calibration.elasticity,
            callPrice: calibration.callPrice,
            putPrice: calibration.putPrice,
        });
        table.generate(data);
    };

    before(async () => {
        // Get signers.
        signers = await ethers.getSigners();
        Admin = signers[0];
        Alice = Admin._address;
        // Standard erc20s with mint functions.
        ETHER = new Token("Ethereum", "ETH", parseEther("10000"));
        DAI = new Token("Dai Stablecoin", "DAI", parseEther("10000"));
        await ETHER.deploy();
        await DAI.deploy();
        // Contracts needed to test and setup test environment.
        contractsToDeploy = ["Pricing", "ProxyPriceProvider"];
        [pricing, oracle] = await setup.deployContracts(contractsToDeploy);
        // Setup oracle with a test price.
        await oracle.setTestPrice(parseEther("105"));
        // Deploy core pool factory, option controller, and option pool.
        optionFactory = await deployOptionFactory(Admin);
        console.log(ETHER.address, DAI.address);
        controller = await deployOptionController(optionFactory, ETHER, DAI);
        pool = await deployOptionPool(controller, oracle, ETHER, DAI);
        // Create a new calibration instance.
        calibration = new Calibration(CONFIG, ETHER, DAI);
        await calibration.initialize(pricing, oracle, pool);
        await generateReport();
    });

    describe("bind", () => {
        afterEach(async () => {
            await generateReport();
        });

        it("should bind initial tokens, with initial weights and amounts", async () => {
            await pool.bind(ETHER.address, calibration.amounts[0], calibration.weights[0].mul(25));
            await pool.bind(DAI.address, calibration.amounts[1], calibration.weights[1].mul(25));
        });
    });

    describe("targetWeightsOverTime", () => {
        afterEach(async () => {
            await generateReport();
        });

        it("should set calibration with a new target weights array", async () => {
            await oracle.setTestPrice("125");
            newCalibration = new Calibration(CONFIG, ETHER, DAI);
            await newCalibration.initialize(pricing, oracle, pool);
            let finalWeightsArray = [
                newCalibration.weights[0].mul(25),
                newCalibration.weights[1].mul(25),
            ];
            let beginBlock = await ethers.getDefaultProvider().getBlockNumber();
            let finalBlock = beginBlock + 100;
            await expect(
                pool.targetWeightsOverTime(finalWeightsArray, beginBlock, finalBlock)
            ).to.emit(pool, "CalibrationUpdated");
        });
    });
});
