pragma solidity =0.5.16;

import "./interfaces/IUniswapV2ERC20.sol";
import "./libraries/SafeMath.sol";

contract UniswapV2ERC20 is IUniswapV2ERC20 {
    using SafeMath for uint256;
    //token名称
    string public constant name = "Uniswap V2";
    //token缩写
    string public constant symbol = "UNI-V2";
    //token精度
    uint8 public constant decimals = 18;
    //总量
    uint256 public totalSupply;
    //余额映射
    mapping(address => uint256) public balanceOf;
    //批准映射，每个地址对每个地址的授权数量
    mapping(address => mapping(address => uint256)) public allowance;

    //域分割，EIP-712中规定的DOMAIN_SEPARATOR
    bytes32 public DOMAIN_SEPARATOR;
    // keccak256('Permit(address owner,address spender,uint value,uint nonce,uint deadline)');
    // EIP-712中规定的TYPEHASH
    bytes32
        public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    //nonces映射，地址与其nonce值，用于避免重放
    mapping(address => uint256) public nonces;

    //批准事件
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    //发送事件
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev 构造函数
     */
    constructor() public {
        // 当前链的id
        uint256 chainId;
        // solium-disable-next-line
        // 通过内联汇编获取chainid
        assembly {
            chainId := chainid
        }
        //EIP712Domain，获取DOMAIN_SEPARATOR
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    function _mint(address to, uint256 value) internal {
        // 增加相应的总供应量
        totalSupply = totalSupply.add(value);
        // 对应地址增加余额
        balanceOf[to] = balanceOf[to].add(value);
        // 触发事件，0地址向目标地址发送相应的代币
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        // 减小余额
        balanceOf[from] = balanceOf[from].sub(value);
        // 减小相应的总供应量
        totalSupply = totalSupply.sub(value);
        // 触发事件 目标地址向0地址发送相应数量的代币
        emit Transfer(from, address(0), value);
    }

    function _approve(
        address owner,
        address spender,
        uint256 value
    ) private {
         // 修改相应的allowance
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(
        address from,
        address to,
        uint256 value
    ) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }
// 调用者向某地址转账
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }
// 授权转账
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool) {
     // 如果授权为最大值，则表示可以转持有者的所有代币
        if (allowance[from][msg.sender] != uint256(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(
                value
            );
        }
        _transfer(from, to, value);
        return true;
    }
// 授权
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        // solium-disable-next-line security/no-block-members
    // 检查时间是否超时
        require(deadline >= block.timestamp, "UniswapV2: EXPIRED");
        // 计算签名
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        owner,
                        spender,
                        value,
                        nonces[owner]++,
                        deadline
                    )
                )
            )
        );
        // 验证签名并获取签名信息的地址
        address recoveredAddress = ecrecover(digest, v, r, s);
        // 确保地址不是0地址且地址是owner地址
        require(
            recoveredAddress != address(0) && recoveredAddress == owner,
            "UniswapV2: INVALID_SIGNATURE"
        );
        // 授权
        _approve(owner, spender, value);
    }
}
