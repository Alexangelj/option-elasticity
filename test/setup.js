const bre = require("@nomiclabs/buidler");
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
const ethers = bre.ethers;

const MAX_UINT = parseEther("10000000000000000000000000000000000000");

const setupTokens = async () => {
    let ether, dai, iEther, iDai;
    ether = await ethers.getContractFactory("PToken");
    ether = await ether.deploy("Ethereum", "ETH", parseEther("100000"));
    dai = await ethers.getContractFactory("PToken");
    dai = await dai.deploy("Dai Stablecoin", "DAI", parseEther("10000000"));
    iEther = await ethers.getContractFactory("IOU");
    iEther = await iEther.deploy();
    iDai = await ethers.getContractFactory("IOU");
    iDai = await iDai.deploy();
    let tokens = {
        ether,
        dai,
        iEther,
        iDai,
    };
    return tokens;
};

const setupMultipleContracts = async (arrayOfContractNames) => {
    let contracts = [];
    for (let i = 0; i < arrayOfContractNames.length; i++) {
        let contractName = arrayOfContractNames[i];
        let factory = await ethers.getContractFactory(contractName);
        let contract = await factory.deploy();
        contracts.push(contract);
    }
    return contracts;
};

const batchApproval = async (arrayOfContractsToApprove, arrayOfTokens, arrayOfOwners) => {
    // for each contract
    for (let c = 0; c < arrayOfContractsToApprove.length; c++) {
        let contract = arrayOfContractsToApprove[c];
        // for each token
        for (let t = 0; t < arrayOfTokens.length; t++) {
            let token = arrayOfTokens[t];
            // for each owner
            for (let u = 0; u < arrayOfOwners.length; u++) {
                let user = arrayOfOwners[u];

                await token.connect(user).approve(contract.address, MAX_UINT);
            }
        }
    }
};

const setupLendingProtocol = async (lendingPool, reserve, trader) => {
    await lendingPool.initialize(reserve.address);
    await reserve.initialize(lendingPool.address);
    await trader.initialize(lendingPool.address);
};

const setupOptionProtocol = async (signer) => {
    // deploys the library
    let templateLib = await deployContract(signer, BPoolTemplateLib, [], {
        gasLimit: 9000000,
    });

    // formats the bytecode so the link() function will work
    let factoryContract = Object.assign(BFactory, {
        evm: { bytecode: { object: BFactory.bytecode } },
    });

    // links the library
    link(
        factoryContract,
        "balancer-core/contracts/BPoolTemplateLib.sol:BPoolTemplateLib",
        templateLib.address
    );

    // gets the contract factory for the option factory
    factory = await ethers.getContractFactory(
        factoryContract.abi,
        factoryContract.evm.bytecode,
        signer
    );

    // deploys the contract
    factory = await factory.deploy();

    // deploys the template address
    await factory.deployBPoolTemplate();

    return factory;
};

const setupOptionPool = async (
    primitiveProxy,
    poolFactory,
    underlyingToken,
    quoteToken,
    signer
) => {
    // get primitive wrapper
    await primitiveProxy.initialize(
        poolFactory.address,
        underlyingToken.address,
        quoteToken.address
    );
    // deploys then initializes pool
    await primitiveProxy.deployPool();
    await primitiveProxy.approvePool();

    // gets the pool instance
    let address = await primitiveProxy.bPool();
    pool = new ethers.Contract(address, BPool.abi, signer);
    return pool;
};

const calibratePool = async (
    signer,
    pool,
    pricingLibrary,
    primitiveProxy,
    riskyAsset,
    riskFreeAsset,
    s,
    k,
    o,
    t
) => {
    let weights = await calculateWeights(pricingLibrary, s, k, o, t);
    let amounts = await calculateAmounts(primitiveProxy, weights);
    await riskyAsset.transfer(primitiveProxy.address, amounts.riskyAmount);
    await riskFreeAsset.transfer(primitiveProxy.address, amounts.riskFreeAmount);
    // initializes with weights and finalizes it
    await primitiveProxy.connect(signer).updateWeights(s, k, o, t);
    await primitiveProxy.finalizePool(pool.address);
};

const calculateWeights = async (pricingLibrary, spot, strike, volatility, timeUntilExpiry) => {
    let weights = await pricingLibrary.getWeights(spot, strike, volatility, timeUntilExpiry);
    return weights;
};

const calculateAmounts = async (primitiveProxy, weights) => {
    let amounts = await primitiveProxy.getAmounts(weights.riskyW, weights.riskFW);
    return amounts;
};

const setupDebtToken = async (reserve, assetToken, debtToken) => {
    await debtToken.initialize(reserve.address);
    await reserve.updateStateWithDebtToken(assetToken.address, debtToken.address);
};

Object.assign(module.exports, {
    setupTokens,
    setupMultipleContracts,
    batchApproval,
    setupLendingProtocol,
    setupDebtToken,
    setupOptionProtocol,
    setupOptionPool,
    calculateWeights,
    calibratePool,
    calculateAmounts,
});
