const bre = require("@nomiclabs/buidler");
const { parseEther } = bre.ethers.utils;
const LendingPool = require("../artifacts/LendingPool.json");
const Reserve = require("../artifacts/Reserve.json");
const TestToken = require("../artifacts/TestToken.json");
const IOU = require("../artifacts/IOU.json");
const BFactory = require("../artifacts/BFactory.json");
const BPool = require("../artifacts/BPool.json");
const BPoolTemplateLib = require("../artifacts/BPoolTemplateLib.json");
const { formatEther, parseUnits } = require("ethers/lib/utils");
const { deployContract, link } = require("ethereum-waffle");
const { BigNumber } = require("ethers");
const ethers = bre.ethers;

const MAX_UINT = parseEther("10000000000000000000000000000000000000");

const setupTokens = async () => {
    let ether, dai, iEther, iDai;
    ether = await ethers.getContractFactory("TestToken");
    ether = await ether.deploy("Ethereum", "ETH", parseEther("100000"));
    dai = await ethers.getContractFactory("TestToken");
    dai = await dai.deploy("Dai Stablecoin", "DAI", parseEther("10000000"));
    iEther = await ethers.getContractFactory("IOU");
    iEther = await iEther.deploy();
    iDai = await ethers.getContractFactory("IOU");
    iDai = await iDai.deploy();
    return [ether, dai, iEther, iDai];
};

const setupDebtToken = async () => {
    debtToken = await ethers.getContractFactory("IOU");
    debtToken = await debtToken.deploy();
    return debtToken;
};

const setupMultipleContracts = async (arrayOfContractNames) => {
    let contracts = [];
    for (let i = 0; i < arrayOfContractNames.length; i++) {
        let contractName = arrayOfContractNames[i];
        console.log(contractName);
        let factory = await ethers.getContractFactory(contractName);
        let contract = await factory.deploy();
        contracts.push(contract);
    }
    console.log("Set up all contracts!");
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
    try {
        await lendingPool.initialize(reserve.address);
        await reserve.initialize(lendingPool.address);
        await trader.initialize(lendingPool.address);
    } catch (error) {
        console.log(error);
    }
};

const setupOptionProtocol = async (signer) => {
    // deploys the library
    let templateLib = await deployContract(signer, BPoolTemplateLib, [], {
        gasLimit: 9500000,
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
    priceProvider,
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
    let corePoolAddress = await primitiveProxy.bPool();
    let optionPool = await ethers.getContractFactory("OptionPool");
    let pool = await optionPool.deploy();
    await primitiveProxy.setController(pool.address);
    await underlyingToken.approve(pool.address, MAX_UINT);
    await quoteToken.approve(pool.address, MAX_UINT);
    await underlyingToken.approve(corePoolAddress, MAX_UINT);
    await quoteToken.approve(corePoolAddress, MAX_UINT);
    await pool.initialize(
        corePoolAddress,
        priceProvider.address,
        "Primitive Option Pool V1",
        "PROP",
        parseEther("1"),
        underlyingToken.address,
        quoteToken.address,
        parseEther("100"),
        31449600
    );
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
    await primitiveProxy.updateWeights(s, k, o, t);
    await primitiveProxy.finalizePool(pool.address);
};

const calculateWeights = async (pricingLibrary, spot, strike, volatility, timeUntilExpiry) => {
    let weights = await pricingLibrary.weights(spot, strike, volatility, timeUntilExpiry);
    return weights;
};

const calculateAmounts = async (primitiveProxy, weights) => {
    let amounts = await primitiveProxy.getAmounts(weights.riskyW, weights.riskFW);
    return amounts;
};

const linkDebtToken = async (reserve, assetToken, debtToken) => {
    await debtToken.initialize(reserve.address);
    await reserve.updateStateWithDebtToken(assetToken.address, debtToken.address);
};

const getMultipleBalances = async (tokensArray, account) => {
    let balancesArray = [];
    for (let i = 0; i < tokensArray.length; i++) {
        let token = tokensArray[i];
        let bal = await token.balanceOf(account);
        balancesArray.push(bal);
    }
    return balancesArray;
};

const getStateOfPool = async (pool, priceProvider, pricing, account) => {
    let totalSupply = await pool.totalSupply();
    let balanceOfAccount = await pool.balanceOf(account);
    let tokens = await pool.getCurrentTokens();
    let ether = tokens[0];
    let dai = tokens[1];
    let etherBalance = await pool.getBalance(ether);
    let daiBalance = await pool.getBalance(dai);
    let etherWeight = await pool.getNormalizedWeight(ether);
    let daiWeight = await pool.getNormalizedWeight(dai);
    let params = await pool.getParameters();
    let spot = await priceProvider.getAssetPrice(ether);
    let weights = await pricing.weights(spot, params.k, params.o, params.t);
    let elasticity = weights.riskyW;
    let optionCallPrice = await pricing.getCallPrice(spot, params.k, params.o, params.t);
    let optionPutPrice = await pricing.getPutPrice(spot, params.k, params.o, params.t);
    let riskFreePerPoolShare = daiBalance.mul(parseEther("1")).div(totalSupply);
    let riskyPerPoolShare = etherBalance.mul(parseEther("1")).div(totalSupply);
    let riskyValuePerPoolShare = riskyPerPoolShare.mul(spot).div(parseEther("1"));
    let totalPoolValuePerShare = riskyValuePerPoolShare.add(riskFreePerPoolShare);

    let state = {
        elasticity: formatEther(elasticity),
        poolSupply: formatEther(totalSupply),
        lpTokenBal: formatEther(balanceOfAccount),
        poolRiskyBal: formatEther(etherBalance),
        poolRiskFreeBal: formatEther(daiBalance),
        poolRiskyWeight: formatEther(etherWeight),
        poolRiskFreeWeight: formatEther(daiWeight),
        optionCallPrice: formatEther(optionCallPrice),
        optionPutPrice: formatEther(optionPutPrice),
        riskyPerPoolShare: formatEther(riskyPerPoolShare),
        riskFreePerPoolShare: formatEther(riskFreePerPoolShare),
        totalPoolValuePerShare: formatEther(totalPoolValuePerShare),
    };
    return state;
};

const getRawStateOfPool = async (pool, priceProvider, pricing, account) => {
    let totalSupply = await pool.totalSupply();
    let balanceOfAccount = await pool.balanceOf(account);
    let tokens = await pool.getCurrentTokens();
    let ether = tokens[0];
    let dai = tokens[1];
    let etherBalance = await pool.getBalance(ether);
    let daiBalance = await pool.getBalance(dai);
    let etherWeight = await pool.getNormalizedWeight(ether);
    let daiWeight = await pool.getNormalizedWeight(dai);
    let params = await pool.getParameters();
    let spot = await priceProvider.getAssetPrice(ether);
    let weights = await pricing.weights(spot, params.k, params.o, params.t);
    let elasticity = weights.riskyW;
    let optionCallPrice = await pricing.getCallPrice(spot, params.k, params.o, params.t);
    let optionPutPrice = await pricing.getPutPrice(spot, params.k, params.o, params.t);
    let riskFreePerPoolShare = daiBalance.mul(parseEther("1")).div(totalSupply);
    let riskyPerPoolShare = etherBalance.mul(parseEther("1")).div(totalSupply);
    let riskyValuePerPoolShare = riskyPerPoolShare.mul(spot).div(parseEther("1"));
    let totalPoolValuePerShare = riskyValuePerPoolShare.add(riskFreePerPoolShare);

    let state = {
        elasticity: elasticity,
        poolSupply: totalSupply,
        lpTokenBal: balanceOfAccount,
        poolRiskyBal: etherBalance,
        poolRiskFreeBal: daiBalance,
        poolRiskyWeight: etherWeight,
        poolRiskFreeWeight: daiWeight,
        optionCallPrice: optionCallPrice,
        optionPutPrice: optionPutPrice,
        riskyPerPoolShare: riskyPerPoolShare,
        riskFreePerPoolShare: riskFreePerPoolShare,
        totalPoolValuePerShare: totalPoolValuePerShare,
    };
    return state;
};

const getStateChangeOfPool = async (oldState, currentState) => {
    let stateChange = {
        elasticity: currentState.elasticity.sub(oldState.elasticity),
        poolSupply: currentState.poolSupply.sub(oldState.poolSupply),
        lpTokenBal: currentState.lpTokenBal.sub(oldState.lpTokenBal),
        poolRiskyBal: currentState.poolRiskyBal.sub(oldState.poolRiskyBal),
        poolRiskFreeBal: currentState.poolRiskFreeBal.sub(oldState.poolRiskFreeBal),
        poolRiskyWeight: currentState.poolRiskyWeight.sub(oldState.poolRiskyWeight),
        poolRiskFreeWeight: currentState.poolRiskFreeWeight.sub(oldState.poolRiskFreeWeight),
        optionCallPrice: currentState.optionCallPrice.sub(oldState.optionCallPrice),
        optionPutPrice: currentState.optionPutPrice.sub(oldState.optionPutPrice),
        riskyPerPoolShare: currentState.riskyPerPoolShare.sub(oldState.riskyPerPoolShare),
        riskFreePerPoolShare: currentState.riskFreePerPoolShare.sub(oldState.riskFreePerPoolShare),
        totalPoolValuePerShare: currentState.totalPoolValuePerShare.sub(
            oldState.totalPoolValuePerShare
        ),
    };
    change = {
        elasticity: formatEther(stateChange.elasticity),
        poolSupply: formatEther(stateChange.poolSupply),
        lpTokenBal: formatEther(stateChange.lpTokenBal),
        poolRiskyBal: formatEther(stateChange.poolRiskyBal),
        poolRiskFreeBal: formatEther(stateChange.poolRiskFreeBal),
        poolRiskyWeight: formatEther(stateChange.poolRiskyWeight),
        poolRiskFreeWeight: formatEther(stateChange.poolRiskFreeWeight),
        optionCallPrice: formatEther(stateChange.optionCallPrice),
        optionPutPrice: formatEther(stateChange.optionPutPrice),
        riskyPerPoolShare: formatEther(stateChange.riskyPerPoolShare),
        riskFreePerPoolShare: formatEther(stateChange.riskFreePerPoolShare),
        totalPoolValuePerShare: formatEther(stateChange.totalPoolValuePerShare),
    };
    return change;
};

Object.assign(module.exports, {
    getRawStateOfPool,
    getStateChangeOfPool,
    getStateOfPool,
    setupTokens,
    setupMultipleContracts,
    batchApproval,
    setupLendingProtocol,
    linkDebtToken,
    setupOptionProtocol,
    setupOptionPool,
    calculateWeights,
    calibratePool,
    calculateAmounts,
    getMultipleBalances,
    setupDebtToken,
});
