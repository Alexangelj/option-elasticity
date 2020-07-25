const bre = require("@nomiclabs/buidler");
const { parseEther } = bre.ethers.utils;
const LendingPool = require("../artifacts/LendingPool.json");
const Reserve = require("../artifacts/Reserve.json");
const PToken = require("../artifacts/PToken.json");
const IOU = require("../artifacts/IOU.json");
const BFactory = require("../artifacts/BFactory.json");
const BPool = require("../artifacts/BPool.json");
const BPoolTemplateLib = require("../artifacts/BPoolTemplateLib.json");
const { formatEther } = require("ethers/lib/utils");
const { deployContract, link } = require("ethereum-waffle");
const ethers = bre.ethers;

const newWallets = async () => {
    const wallets = await ethers.getSigners();
    return wallets;
};

describe("Reserve/Lending Contract", () => {
    let wallets, Admin, Alice, lending, reserve, asset, iou, trader;
    let risky, riskFree, pricing, factory, pfi;
    let s, k, o, t;

    const DENOMINATOR = 2 ** 64;

    before(async () => {
        // get wallets
        wallets = await newWallets();
        Admin = wallets[0];
        Alice = Admin._address;
        asset = await ethers.getContractFactory("PToken");
        asset = await asset.deploy("Test Asset", "ASSET", parseEther("1000"));
        lending = await ethers.getContractFactory("LendingPool");
        lending = await lending.deploy();
        reserve = await ethers.getContractFactory("Reserve");
        reserve = await reserve.deploy();
        iou = await ethers.getContractFactory("IOU");
        iou = await iou.deploy();
        trader = await ethers.getContractFactory("Trader");
        trader = await trader.deploy();
        await lending.initialize(reserve.address);
        await reserve.initialize(lending.address);
        await iou.initialize(reserve.address);
        await trader.initialize(lending.address);
        await reserve.updateStateWithDebtToken(asset.address, iou.address);
        await asset.approve(lending.address, parseEther("100000000000000"));

        // pool stuff

        risky = await ethers.getContractFactory("PToken");
        risky = await risky.deploy("Risky Asset", "RISK", parseEther("10000"));
        riskFree = await ethers.getContractFactory("PToken");
        riskFree = await riskFree.deploy("Risk Free Asset", "FREE", parseEther("10000"));
        await asset.approve(lending.address, parseEther("100000000000000"));
        await risky.approve(lending.address, parseEther("100000000000000"));
        await risky.approve(lending.address, parseEther("100000000000000"));

        // get pricing contract, could be a library tbh
        pricing = await ethers.getContractFactory("Pricing");
        pricing = await pricing.deploy();

        // get parameters, s = spot = x, k = strike, o = sigma = volatility, t = T until expiry
        s = parseEther("101");
        k = parseEther("100");
        o = 100;
        t = 31449600; //one year

        // get balancer factory
        let templateLib = await deployContract(Admin, BPoolTemplateLib, [], {
            gasLimit: 9000000,
        });
        let factoryContract = Object.assign(BFactory, {
            evm: { bytecode: { object: BFactory.bytecode } },
        });
        link(
            factoryContract,
            "balancer-core/contracts/BPoolTemplateLib.sol:BPoolTemplateLib",
            templateLib.address
        );
        factory = await ethers.getContractFactory(
            factoryContract.abi,
            factoryContract.evm.bytecode,
            Admin
        );
        factory = await factory.deploy();

        // get primitive wrapper
        pfi = await ethers.getContractFactory("PFactory");
        pfi = await pfi.deploy();
        await pfi.initialize(factory.address, risky.address, riskFree.address);
    });

    describe("Test Reserve Functions", () => {
        it("initializes with enter()", async () => {
            await lending.enter(Alice, asset.address, parseEther("1"));
        });

        it("calls enter() after initialized 2", async () => {
            await lending.enter(Alice, asset.address, parseEther("1"));
            await lending.enter(Alice, asset.address, parseEther("1"));
            await lending.enter(Alice, asset.address, parseEther("1"));
            await lending.enter(Alice, asset.address, parseEther("1"));
            await lending.enter(Alice, asset.address, parseEther("1"));
            await lending.enter(Alice, asset.address, parseEther("1"));
        });

        it("calls updateState() directly", async () => {
            await asset.transfer(reserve.address, parseEther("10"));
            await reserve.updateStateWithDeposit(Alice, asset.address, parseEther("5"));
            await reserve.updateStateWithDeposit(Alice, asset.address, parseEther("5"));
        });
    });

    describe("buyOption", () => {
        it("should buy an option", async () => {
            await pfi.deployPool();
            await pfi.approvePool();
            await risky.approve(pfi.address, parseEther("1000000000"));
            await riskFree.approve(pfi.address, parseEther("1000000000"));
            let address = await pfi.bPool();
            pool = new ethers.Contract(address, BPool.abi, Admin);
            let weights = await pricing.getWeights(s, k, o, t);
            let amounts = await pfi.getAmounts(weights.riskyW, weights.riskFW);
            await risky.transfer(pfi.address, amounts.riskyAmount);
            await riskFree.transfer(pfi.address, amounts.riskFreeAmount);
            await pfi.connect(Admin).updateWeights(s, k, o, t, { from: Alice });
            await pool.finalize();
            await trader.buyOption(pool.address, parseEther("1"));
        });
    });
});
