const bre = require("@nomiclabs/buidler");
const { assert, expect } = require("chai");
const chai = require("chai");
const { solidity } = require("ethereum-waffle");
chai.use(solidity);
const { parseEther } = bre.ethers.utils;
const LendingPool = require("../artifacts/LendingPool.json");
const Reserve = require("../artifacts/Reserve.json");
const PToken = require("../artifacts/PToken.json");
const IOU = require("../artifacts/IOU.json");
const BFactory = require("../artifacts/BFactory.json");
const BPool = require("../artifacts/BPool.json");
const BPoolTemplateLib = require("../artifacts/BPoolTemplateLib.json");
const { formatEther, parseUnits } = require("ethers/lib/utils");
const { deployContract, link } = require("ethereum-waffle");
const {
    setupTokens,
    setupMultipleContracts,
    batchApproval,
    setupLendingProtocol,
    linkDebtToken,
    setupOptionProtocol,
    setupOptionPool,
    calibratePool,
    getMultipleBalances,
    setupDebtToken,
} = require("./setup.js");

const ethers = bre.ethers;

const newWallets = async () => {
    const wallets = await ethers.getSigners();
    return wallets;
};

describe("OptionPool.sol", () => {
    let wallets, Admin, Alice, lending, reserve, asset, trader, debtToken;
    let ether, dai, iEther, iDai, iPool;
    let risky, riskFree, pricing, poolFactory, primitiveFactory;
    let s, k, o, t;
    let etherBalance, daiBalance, iEtherBalance, iDaiBalance;

    const DENOMINATOR = 2 ** 64;

    before(async () => {
        // get wallets
        wallets = await newWallets();
        Admin = wallets[0];
        Alice = Admin._address;
        // standard erc20s with mint functions
        // iou mappings at a 1:1 ratio with undelying asset. Deposit 1 ether => get 1 iEther
        [ether, dai] = await setupTokens();

        // pricing is the black-scholes library, primitiveFactory deploys the option pools
        [pricing, primitiveFactory] = await setupMultipleContracts([
            "Pricing",
            "PFactory",
        ]);

        // get parameters, s = spot = x, k = strike, o = sigma = volatility, t = T until expiry
        s = parseEther("101");
        k = parseEther("100");
        o = 100;
        t = 31449600; //one year

        // get the actual Bpool factory
        poolFactory = await setupOptionProtocol(Admin);

        // get the first pool that was deployed
        pool = await setupOptionPool(primitiveFactory, poolFactory, ether, dai, Admin);

        // approve tokens
        let contractsToApprove = [primitiveFactory];
        let tokensToBeApproved = [ether, dai, pool];
        let ownersToApprove = [Admin];
        await batchApproval(contractsToApprove, tokensToBeApproved, ownersToApprove);

        // initial balances
        [etherBalance, daiBalance, iEtherBalance, iDaiBalance] = await getMultipleBalances(
            tokensToBeApproved,
            Alice
        );
    });

    describe("OptionPool View Functions", () => {
        it("should have the same name", async () => {
            console.log((await pool.getDenormalizedWeight(ether.address)).toString());
        });
    });
});
