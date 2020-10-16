const { deployContract, link } = require("ethereum-waffle");
const BFactory = require("../../../artifacts/BFactory.json");
const BPoolTemplateLib = require("../../../artifacts/BPoolTemplateLib.json");
const formatBytecode = require("./formatBytecode");
const overrideOptions = require("./overrideOptions");

const deployOptionFactory = async (signer) => {
    // deploys the library
    let templateLib = await deployContract(signer, BPoolTemplateLib, [], overrideOptions);

    // formats the bytecode so the link() function will work
    let factoryArtifact = formatBytecode(BFactory);

    // links the library
    link(
        factoryArtifact,
        "balancer-core/contracts/BPoolTemplateLib.sol:BPoolTemplateLib",
        templateLib.address
    );

    // gets the contract factory for the option factory
    let factory = await ethers.getContractFactory(
        factoryArtifact.abi,
        factoryArtifact.evm.bytecode,
        signer
    );

    // deploys the contract
    let contract = await factory.deploy();

    // deploys the template address
    await contract.deployBPoolTemplate();

    return contract;
};

module.exports = deployOptionFactory;
