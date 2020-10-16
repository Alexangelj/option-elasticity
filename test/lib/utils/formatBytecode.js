const formatBytecode = (artifact) => {
    // formats the bytecode so the link() function will work
    let formattedContract = Object.assign(artifact, {
        evm: { bytecode: { object: artifact.bytecode } },
    });

    return formattedContract;
};

module.exports = formatBytecode;
