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

const MAX_UINT = 2**256-1;

const setupTokens = async () => {
    let ether, dai, iou;
    ether = await ethers.getContractFactory("PToken");
    ether = await ether.deploy("Ethereum", "ETH", parseEther("100000"));
    dai = await ethers.getContractFactory("PToken");
    dai = await dai.deploy("Dai Stablecoin", "DAI", parseEther("10000000"));
    iou = await ethers.getContractFactory("IOU");
    iou = await iou.deploy();
    let tokens = {
        ether,
        dai,
        iou
    }
    return tokens;
}

const setupMultipleContracts = async (arrayOfContractNames) => {
    let contracts = [];
    for(let i =0; i < arrayOfContractNames.length; i++) {
        let contractName = arrayOfContractNames[i];
        let factory = await ethers.getContractFactory(contractName);
        let contract = await factory.deploy();
        contracts.push(contract);
    }
    return contracts;
}

const batchApproval = async (arrayOfContractsToApprove, arrayOfTokens, arrayOfOwners) => {
    // for each contract
    for(let c =0; c < arrayOfContractsToApprove.length; c++) {
        let contract = arrayOfContractsToApprove[c];
        // for each token
        for(let t = 0; t < arrayOfTokens.length; t++) {
            let token = arrayOfTokens[t];
            // for each owner
            for(let u = 0; u < arrayOfOwners.length; u++) {
                let user = arrayOfOwners[u];

                await token.connect(user).approve(contract.address, MAX_UINT);
            }
        }
    }
    return contracts;
}

const setupLendingProtocol = async (lendingPool, reserve, trader) => {
    await lendingPool.initialize(reserve.address);
    await reserve.initialize(lendingPool.address);
    await trader.initialize(lendingPool.address);
}

const setupDebtToken = async (reserve, assetToken, debtToken) => {
    await debtToken.initialize(reserve.address);
    await reserve.updateStateWithDebtToken(assetToken.address, debtToken.address);
}

Object.assign(module.exports, {
    setupTokens,
    setupMultipleContracts,
    batchApproval,
    setupLendingProtocol,
    setupDebtToken
});