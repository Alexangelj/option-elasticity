const bre = require("@nomiclabs/buidler");
const ethers = bre.ethers;

const deployContracts = async (arrayOfContractNames) => {
    let contracts = [];
    for (let i = 0; i < arrayOfContractNames.length; i++) {
        let contractName = arrayOfContractNames[i];
        let factory = await ethers.getContractFactory(contractName);
        let contract = await factory.deploy();
        contracts.push(contract);
    }
    return contracts;
};

Object.assign(module.exports, {
    deployContracts,
});
