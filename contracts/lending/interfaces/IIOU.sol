pragma solidity >=0.5.12 <=0.6.2;

interface IIOU {
    function mint(address to, uint256 quantity) external returns (bool);

    function burn(address to, uint256 quantity) external returns (bool);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);
}
