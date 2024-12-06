pragma solidity =0.5.16;

import "./interfaces/IUniswapV2Pair.sol";
import "./UniswapV2ERC20.sol";
import "./libraries/Math.sol";
import "./libraries/UQ112x112.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Callee.sol";

/*
* 保存单个交易对的资金池信息, 包括每个交易对中两个ERC20 代币的地址, 以及各自资金余额(reserve);
* 处理 mint, burn 和 交易(swap) 操作. Pair合约是Uniswap代码的核心
* UniswapV2Pair 本身也是ERC20, 当添加流动性时会mint新的pair代币(pair token, or LP token), 
* 删除流动性时会销毁一定数量的代币, 确保 pair token的 totalSupply 始终等于池子中的两个交易对代币余额的几何平均值: 
* totalSupply of pair token === sqrt(reserve1 * reserve2)
*/
//Uniswap配对合约，继承了这两个合约。UniswapV2ERC20里面有个permit函数。
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
using SafeMath for uint256;
// UQ112x112库，将224分为两个部分，一个112最为整数部分，另一个112作为浮点数,保留32位。
using UQ112x112 for uint224;
//方法赋予到了类型里，这样的话，所有的uint256和uint224类型就有了各种方法，比如 uint256.mul()
//最小流动性 = 1000
uint256 public constant MINIMUM_LIQUIDITY = 10**3;
// transfer的函数签名，SELECTOR常量值为'transfer(address,uint256)'字符串哈希值的前4位16进制数字
bytes4 private constant SELECTOR = bytes4(
    keccak256(bytes("transfer(address,uint256)"))
);
    
address public factory; //工厂地址
address public token0; //token0地址/
address public token1; //token1地址

uint112 private reserve0; // 储备量0
uint112 private reserve1; // 储备量1
// 用于判断是不是区块的第一笔交易的时间戳
uint32 private blockTimestampLast; // 更新储备量的最后时间戳
// 价格的最后累计，用于周边合约的预言机
uint256 public price0CumulativeLast;//价格0最后累计//用于价格预言机
uint256 public price1CumulativeLast;//价格1最后累计//用于价格预言机

//在最近一次流动性事件之后的K值
//储备量0*储备量1，自最近一次流动性事件发生后
uint256 public kLast;
//锁定变量,防止重入
uint256 private unlocked = 1;

//事件:铸造
event Mint(address indexed sender, uint256 amount0, uint256 amount1);
//事件:销毁
event Burn(
    address indexed sender,
    uint256 amount0,
    uint256 amount1,
    address indexed to
);
/**
 * @dev 事件:交换
 * @param sender 发送者
 * @param amount0In 输入金额0
 * @param amount1In 输入金额1
 * @param amount0Out 输出金额0
 * @param amount1Out 输出金额1
 * @param to to地址
 */
event Swap(
    address indexed sender,
    uint256 amount0In,
    uint256 amount1In,
    uint256 amount0Out,
    uint256 amount1Out,
    address indexed to
);
/**
 * @dev 事件:同步
 * @param reserve0 储备量0
 * @param reserve1 储备量1
 */
event Sync(uint112 reserve0, uint112 reserve1);

/**
 * @dev 构造函数
 */
constructor() public {
    //factory地址为合约布署者
    factory = msg.sender;
}

/**
 * @param _token0 token0
 * @param _token1 token1
 * @dev 初始化方法,部署时由工厂调用一次
 */
// 因为该合约是使用create2的方式部署，所以构造函数不能有任何参数;
// 就需要initalize函数初始化两个token地址
function initialize(address _token0, address _token1) external {
    //确认调用者为工厂地址
    require(msg.sender == factory, "UniswapV2: FORBIDDEN");
    token0 = _token0;
    token1 = _token1;
}

/**
 * @dev 修饰符:锁定运行防止重入
 */
modifier lock() {
    require(unlocked == 1, "UniswapV2: LOCKED");
    unlocked = 0;
    _;
    unlocked = 1;
}

/**
 * @return _reserve0 储备量0
 * @return _reserve1 储备量1
 * @return _blockTimestampLast 时间戳
 * @dev 获取储备
 */
// 获取两种代币的储备量与上一个区块的时间戳
function getReserves()
    public
    view
    returns (
        uint112 _reserve0,
        uint112 _reserve1,
        uint32 _blockTimestampLast
    )
{
    _reserve0 = reserve0;
    _reserve1 = reserve1;
    _blockTimestampLast = blockTimestampLast;
}

/**
 * @param token token地址
 * @param to    to地址
 * @param value 数额
 * @dev 私有安全发送
 */
function _safeTransfer(
    address token,
    address to,
    uint256 value
) private {
    //调用token合约地址的低级transfer方法
    //solium-disable-next-line
    (bool success, bytes memory data) = token.call(
        abi.encodeWithSelector(SELECTOR, to, value)
    );
    //确认返回值为true并且返回的data长度为0或者解码后为true
    require(
        success && (data.length == 0 || abi.decode(data, (bool))),
        "UniswapV2: TRANSFER_FAILED"
    );
}

/**
 * @param balance0 余额0
 * @param balance1  余额1
 * @param _reserve0 储备0
 * @param _reserve1 储备1
 * @dev 更新储量，并在每个区块的第一次调用时更新价格累加器
 */
function _update(
    uint256 balance0,
    uint256 balance1,
    uint112 _reserve0,
    uint112 _reserve1
) private {
    //确认余额0和余额1小于等于最大的uint112
    // 防止溢出
    require(
        balance0 <= uint112(-1) && balance1 <= uint112(-1),
        "UniswapV2: OVERFLOW"
    );
    //区块时间戳,将时间戳转换为uint32
    //solium-disable-next-line
    // 计算当前时间戳-最近一次流动性事件的时间戳
    uint32 blockTimestamp = uint32(block.timestamp % 2**32);
    //计算时间流逝
    uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
    //如果时间流逝>0 并且 储备量0,1不等于0
    if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
        // * never overflows, and + overflow is desired
        //价格0最后累计 += 储备量1 * 2**112 / 储备量0 * 时间流逝
        //solium-disable-next-line 
        //用于价格预言机
        price0CumulativeLast +=
            uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) *
            timeElapsed;
        //价格1最后累计 += 储备量0 * 2**112 / 储备量1 * 时间流逝
        //solium-disable-next-line 
        price1CumulativeLast +=
            uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) *
            timeElapsed;
    } 
    //余额0,1放入储备量0,1
    reserve0 = uint112(balance0);
    reserve1 = uint112(balance1);
    //更新最后时间戳
    blockTimestampLast = blockTimestamp;
    //触发同步事件
    emit Sync(reserve0, reserve1);
}

/**
 * @param _reserve0 储备0
 * @param _reserve1 储备1
 * @return feeOn//feeOn打开就会分一部分手续费给项目方（1/6），目前一直没有打开。
 * @dev 如果收费，铸造流动性相当于1/6的增长sqrt（k）
 */
function _mintFee(uint112 _reserve0, uint112 _reserve1)
    private
    returns (bool feeOn)
{
    //查询工厂合约的feeTo变量值
    // 获取平台收取手续费地址
    address feeTo = IUniswapV2Factory(factory).feeTo();
    //如果feeTo不等于0地址,feeOn等于true否则为false
    // 开启平台收取手续费
    feeOn = feeTo != address(0);
    //定义k值
    uint256 _kLast = kLast; // gas savings
    //如果feeOn等于true
    //feeOn打开是分一部分手续费给项目方（1/6），目前一直没有打开。
    if (feeOn) {
        //如果k值不等于0
        if (_kLast != 0) {
            //计算(_reserve0*_reserve1)的平方根
            // 计算现在k的平方根
            uint256 rootK = Math.sqrt(uint256(_reserve0).mul(_reserve1));
            //计算k值的平方根
            // 计算之前的k的平方根
            uint256 rootKLast = Math.sqrt(_kLast);
            //如果rootK>rootKLast
            // 通常情况下，k值应该为增加的
            if (rootK > rootKLast) {
                // 计算要给平台的手续费
                //分子 = erc20总量 * (rootK - rootKLast)
                uint256 numerator = totalSupply.mul(rootK.sub(rootKLast));
                //分母 = rootK * 5 + rootKLast
                uint256 denominator = rootK.mul(5).add(rootKLast);
                //流动性 = 分子 / 分母
                uint256 liquidity = numerator / denominator;
                // 如果流动性 > 0 将流动性铸造给feeTo地址
                if (liquidity > 0) _mint(feeTo, liquidity);
            }
        }
        //否则如果_kLast不等于0
    } else if (_kLast != 0) {
        //k值=0
        kLast = 0;
    }
}

/**
 * @param to to地址
 * @return liquidity 流动性数量
 * @dev 铸造方法
 * @notice 应该从执行重要安全检查的合同中调用此低级功能
 */
// this low-level function should be called from a contract which performs important safety checks
// 给流动性提供者铸币

// 1.先获取两token的储备量和本合约中两种代币的余额
// 2.通过余额和储备量相减获取增加量
// 3.如果是初始化，则流动性为两增加量的算术平方根减去最小流动性，如果新加流动性，则按照两种代币数量增加小的为准增加流动性;
// 4.将Lp mint给提供流动性的地址
// 5.更新两种代币的储备量
function mint(address to) external lock returns (uint256 liquidity) {
    //获取`储备量0`,`储备量1`
    (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings直接返回3个值，这里只需要2个值。
    // 这个合约中两个token的余额
    uint256 balance0 = IERC20(token0).balanceOf(address(this));//获取当前合约在token0合约内的余额
    uint256 balance1 = IERC20(token1).balanceOf(address(this));//获取当前合约在token1合约内的余额
    // 获取两种代币的增加量
    uint256 amount0 = balance0.sub(_reserve0);//amount0 = 余额0 - 储备0
    uint256 amount1 = balance1.sub(_reserve1);//amount1 = 余额1 - 储备1

    //返回铸造费开关
    // 是否开启手续费，feeOn初始值为0
    bool feeOn = _mintFee(_reserve0, _reserve1);
    //获取totalSupply,必须在此处定义，因为totalSupply可以在mintFee中更新
    // 获取总供应量
    uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
    //如果_totalSupply等于0
    // 如果总供应量为0，即初始化的时候
    if (_totalSupply == 0) {
        //流动性 = (数量0 * 数量1)的平方根 - 最小流动性1000
        // 流动性为两数的算数平方根减去最小流动性
        liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
        //在总量为0的初始状态,永久锁定最低流动性
        // 向0地址锁定最小流动性
        _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
    } else {
        // 如果流动性不为0，则按照两种代币的增加比例添加新的流动性
        //流动性 = 最小值 (amount0 * _totalSupply / _reserve0) 和 (amount1 * _totalSupply / _reserve1)
        liquidity = Math.min(
            amount0.mul(_totalSupply) / _reserve0,
            amount1.mul(_totalSupply) / _reserve1
        );
    }
    //确认流动性 > 0
    require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
    //铸造流动性给to地址
    _mint(to, liquidity);

    //更新储备量
    _update(balance0, balance1, _reserve0, _reserve1);
    //如果铸造费开关为true, k值 = 储备0 * 储备1
    // 如果开启收费，则k值为两储备量相乘 x * y = K
    if (feeOn) kLast = uint256(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
    //触发铸造事件
    emit Mint(msg.sender, amount0, amount1);
}

/**
 * @param to to地址
 * @return amount0
 * @return amount1
 * @dev 销毁方法
 * @notice 应该从执行重要安全检查的合同中调用此低级功能
 */
// this low-level function should be called from a contract which performs important safety checks
// 撤回流动性

// 1.获取合约中两种代币的储备量与余额
// 2.获取路由合约发送到本合约的Lptoken
// 3.按照Lp在总供应量中的比例取走相应数量的代币
// 4.销毁本合约中所有的流动性
// 5.更新余额和供应量
function burn(address to)
    external
    lock
    returns (uint256 amount0, uint256 amount1)
{
    //获取`储备量0`,`储备量1`
    (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
    //带入变量
    address _token0 = token0; // gas savings
    address _token1 = token1; // gas savings
    // 两种代币在合约中的余额
    uint256 balance0 = IERC20(_token0).balanceOf(address(this));//获取当前合约在token0合约内的余额
    uint256 balance1 = IERC20(_token1).balanceOf(address(this));//获取当前合约在token1合约内的余额
    //从当前合约的balanceOf映射中获取当前合约自身的流动性数量
    // 流动性为用户由路由合约发送到本pair合约的要销毁的金额
    uint256 liquidity = balanceOf[address(this)];

    //返回铸造费开关
    bool feeOn = _mintFee(_reserve0, _reserve1);
    //获取totalSupply,必须在此处定义，因为totalSupply可以在mintFee中更新
    // 获取总供应量
    uint256 _totalSupply = totalSupply; 
    // gas savings, must be defined here since totalSupply can update in _mintFee
    // 按照用户在总供应量中的比例取走相应的代币，其中已经含有相应的手续费奖励
    //amount0 =  余额0 * 流动性数量 / totalSupply   使用余额确保按比例分配
    amount0 = liquidity.mul(balance0) / _totalSupply; 
    // using balances ensures pro-rata distribution
    //amount1 =  余额1 * 流动性数量 / totalSupply   使用余额确保按比例分配
    amount1 = liquidity.mul(balance1) / _totalSupply; 
    // using balances ensures pro-rata distribution
    //确认amount0和amount1都大于0
    require(
        amount0 > 0 && amount1 > 0,
        "UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED"
    );
    //销毁当前合约内的流动性数量
    // 销毁本合约内的所有流动性
    _burn(address(this), liquidity);
    //将amount0数量的_token0发送给to地址
    _safeTransfer(_token0, to, amount0);
    //将amount1数量的_token1发送给to地址
    _safeTransfer(_token1, to, amount1);
    //更新balance0
    balance0 = IERC20(_token0).balanceOf(address(this));
    //更新balance1
    balance1 = IERC20(_token1).balanceOf(address(this));

    //更新储备量
    _update(balance0, balance1, _reserve0, _reserve1);
    //如果铸造费开关为true, k值 = 储备0 * 储备1
    if (feeOn) kLast = uint256(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
    //触发销毁事件
    emit Burn(msg.sender, amount0, amount1, to);
}

/**
 * @param amount0Out 输出数额0
 * @param amount1Out 输出数额1
 * @param to    to地址
 * @param data  用于回调的数据
 * @dev 交换方法
 * @notice 应该从执行重要安全检查的合同中调用此低级功能
 */
// this low-level function should be called from a contract which performs important safety checks
// 交易token，需要输入两种token的量，token要发送到的地址，data用于闪电贷的回调
function swap(
    uint256 amount0Out,
    uint256 amount1Out,
    address to,
    bytes calldata data
) external lock {
    //确认amount0Out和amount1Out都大于0
    require(
        amount0Out > 0 || amount1Out > 0,
        "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"
    );
    //获取`储备量0`,`储备量1`
    (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
    //确认`输出数量0,1` < `储备量0,1`
    require(
        amount0Out < _reserve0 && amount1Out < _reserve1,
        "UniswapV2: INSUFFICIENT_LIQUIDITY"
    );

    //初始化变量
    uint256 balance0;
    uint256 balance1;
    {
    //这个大括号不是什么方法，是定义下面这一段为一个作用于，所有的变量和计算在这里完成。
        //标记_token{0,1}的作用域，避免堆栈太深的错误
        // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;

        //确认to地址不等于_token0和_token1
        require(to != _token0 && to != _token1, "UniswapV2: INVALID_TO");
        //如果`输出数量0` > 0 安全发送`输出数量0`的token0到to地址
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        //如果`输出数量1` > 0 安全发送`输出数量1`的token1到to地址
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        //如果data的长度大于0 调用to地址的接口
        if (data.length > 0)
            IUniswapV2Callee(to).uniswapV2Call(
                msg.sender,
                amount0Out,
                amount1Out,
                data
            );
        //`余额0,1` = 当前合约在`token0,1`合约内的余额
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
    }
    //如果 余额0 > 储备0 - amount0Out 则 amount0In = 余额0 - (储备0 - amount0Out) 否则 amount0In = 0
    uint256 amount0In = balance0 > _reserve0 - amount0Out
        ? balance0 - (_reserve0 - amount0Out)
        : 0;
    //如果 余额1 > 储备1 - amount1Out 则 amount1In = 余额1 - (储备1 - amount1Out) 否则 amount1In = 0
    uint256 amount1In = balance1 > _reserve1 - amount1Out
        ? balance1 - (_reserve1 - amount1Out)
        : 0;
    //确认`输入数量0||1`大于0
    require(
        amount0In > 0 || amount1In > 0,
        "UniswapV2: INSUFFICIENT_INPUT_AMOUNT"
    );
    {
        //标记reserve{0,1}的作用域，避免堆栈太深的错误
        // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        //调整后的余额0 = 余额0 * 1000 - (amount0In * 3)
        uint256 balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        //调整后的余额1 = 余额1 * 1000 - (amount1In * 3)
        uint256 balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        //确认balance0Adjusted * balance1Adjusted >= 储备0 * 储备1 * 1000000
        require(
            balance0Adjusted.mul(balance1Adjusted) >=
                uint256(_reserve0).mul(_reserve1).mul(1000**2),
            "UniswapV2: K"
        );
    }

    //更新储备量
    _update(balance0, balance1, _reserve0, _reserve1);
    //触发交换事件
    emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
}

/**
 * @param to to地址
 * @dev 强制平衡以匹配储备
 */
// force balances to match reserves
function skim(address to) external lock {
    address _token0 = token0; // gas savings
    address _token1 = token1; // gas savings
    //将当前合约在`token0,1`的余额-`储备量0,1`安全发送到to地址
    _safeTransfer(
        _token0,
        to,
        IERC20(_token0).balanceOf(address(this)).sub(reserve0)
    );
    _safeTransfer(
        _token1,
        to,
        IERC20(_token1).balanceOf(address(this)).sub(reserve1)
    );
}

/**
 * @dev 强制准备金与余额匹配
 */
// force reserves to match balances
function sync() external lock {
    _update(
        IERC20(token0).balanceOf(address(this)),
        IERC20(token1).balanceOf(address(this)),
        reserve0,
        reserve1
    );
}
}
