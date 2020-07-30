pragma solidity >=0.5.12 <=0.6.2;

interface IProxyPriceProvider {
    function getAssetPrice(address assetAddress) external view returns (uint price);
}