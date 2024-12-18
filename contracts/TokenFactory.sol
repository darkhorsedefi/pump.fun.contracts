// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import {BancorBondingCurve} from "./BancorBondingCurve.sol";
import {Token} from "./Token.sol";

contract TokenFactory is ReentrancyGuard, Ownable {
    enum TokenState {
        NOT_CREATED,
        FUNDING,
        TRADING
    }

    uint256 public constant MAX_SUPPLY = 10 ** 9 * 1 ether; // 1 Billion
    uint256 public constant INITIAL_SUPPLY = (MAX_SUPPLY * 1) / 5;
    uint256 public constant FUNDING_SUPPLY = (MAX_SUPPLY * 4) / 5;
    uint256 public constant FUNDING_GOAL = 20 ether;
    uint256 public constant FEE_DENOMINATOR = 10000;

    mapping(address => TokenState) public tokens;

    mapping(uint256 => address[]) public tokensByCompetitionId;

    mapping(address => uint256) public competitionIds;
    uint256 public currentCompetitionId = 0;

    address public immutable tokenImplementation;
    address public uniswapV2Router;
    address public uniswapV2Factory;
    BancorBondingCurve public bondingCurve;
    uint256 public feePercent; // bp
    uint256 public fee;

    mapping(uint256 => address) public winners;
    mapping(uint256 => mapping(address => uint256)) public collateralById;

    // Events
    event TokenCreated(
        address indexed token,
        string name,
        string symbol,
        string uri,
        address creator,
        uint256 competitionId,
        uint256 timestamp
    );

    event TokenLiqudityAdded(address indexed token, uint256 timestamp);

    event TokenBuy(
        address indexed token,
        uint256 amount0In,
        uint256 amount0Out,
        uint256 fee,
        uint256 timestamp
    );

    event TokenSell(
        address indexed token,
        uint256 amount0In,
        uint256 amount0Out,
        uint256 fee,
        uint256 timestamp
    );

    event SetWinner(
        address indexed winner, 
        uint256 competitionId,
        uint256 timestamp
    );

    event BurnTokenAndMintWinner(
        address indexed sender,
        address indexed token,
        address indexed winnerToken,
        uint256 burnedAmount,
        uint256 receivedETH,
        uint256 mintedAmount,
        uint256 timestamp
    );

    constructor(
        address _tokenImplementation,
        address _uniswapV2Router,
        address _uniswapV2Factory,
        address _bondingCurve,
        uint256 _feePercent
    ) Ownable(msg.sender) {
        tokenImplementation = _tokenImplementation;
        uniswapV2Router = _uniswapV2Router;
        uniswapV2Factory = _uniswapV2Factory;
        bondingCurve = BancorBondingCurve(_bondingCurve);
        feePercent = _feePercent;
    }

    modifier inCompetition(address tokenAddress) {
        require(
            competitionIds[tokenAddress] == currentCompetitionId,
            "The competition for this token has already ended"
        );
        _;
    }

    // Admin functions

    function startNewCompetition() external onlyOwner {
        currentCompetitionId = currentCompetitionId + 1;
    }

    function setBondingCurve(address _bondingCurve) external onlyOwner {
        bondingCurve = BancorBondingCurve(_bondingCurve);
    }

    function setFeePercent(uint256 _feePercent) external onlyOwner {
        feePercent = _feePercent;
    }

    function claimFee() external onlyOwner {
        (bool success, ) = msg.sender.call{value: fee}(new bytes(0));
        require(success, "ETH send failed");
        fee = 0;
    }

    // Token functions

    function createToken(
        string memory name,
        string memory symbol,
        string memory uri
    ) external returns (address) {
        address tokenAddress = Clones.clone(tokenImplementation);
        Token token = Token(tokenAddress);
        token.initialize(name, symbol, uri, address(this));
        tokens[tokenAddress] = TokenState.FUNDING;

        tokensByCompetitionId[currentCompetitionId].push(tokenAddress);

        competitionIds[tokenAddress] = currentCompetitionId;

        emit TokenCreated(
            tokenAddress,
            name,
            symbol,
            uri,
            msg.sender,
            currentCompetitionId,
            block.timestamp
        );

        return tokenAddress;
    }

    function buy(address tokenAddress) external payable nonReentrant inCompetition(tokenAddress) {
        _buy(tokenAddress, msg.sender, msg.value);
    }

    function _buy(
        address tokenAddress,
        address receiver,
        uint256 valueToBuy
    ) internal returns (uint256) {
        require(tokens[tokenAddress] == TokenState.FUNDING, "Token not found");
        require(valueToBuy > 0, "ETH not enough");
        // calculate fee
        uint256 valueToReturn;
        uint256 _competitionId = competitionIds[tokenAddress];
        uint256 tokenCollateral = collateralById[_competitionId][tokenAddress];

        uint256 remainingEthNeeded = FUNDING_GOAL - tokenCollateral;
        uint256 contributionWithoutFee = (valueToBuy * FEE_DENOMINATOR) /
            (FEE_DENOMINATOR + feePercent);
        if (contributionWithoutFee > remainingEthNeeded) {
            contributionWithoutFee = remainingEthNeeded;
        }
        uint256 _fee = calculateFee(contributionWithoutFee, feePercent);
        uint256 totalCharged = contributionWithoutFee + _fee;
        valueToReturn = valueToBuy > totalCharged
            ? valueToBuy - totalCharged
            : 0;
        fee += _fee;
        Token token = Token(tokenAddress);
        uint256 amount = bondingCurve.computeMintingAmountFromPrice(
            collateralById[_competitionId][tokenAddress],
            token.totalSupply(),
            contributionWithoutFee
        );
        uint256 availableSupply = FUNDING_SUPPLY - token.totalSupply();
        require(amount <= availableSupply, "Token supply not enough");
        tokenCollateral += contributionWithoutFee;
        token.mint(receiver, amount);

        collateralById[_competitionId][tokenAddress] = tokenCollateral;

        // TODO - return left not working for burnTokenAndMintWinner case
        // return left
        // if (valueToReturn > 0) {
        //     (bool success, ) = receiver.call{value: amount - valueToBuy}(
        //         new bytes(0)
        //     );
        //     require(success, "ETH send failed");
        // }

        emit TokenBuy(tokenAddress, valueToBuy, amount, fee, block.timestamp);

        return (amount);
    }

    function sell(address tokenAddress, uint256 amount) external nonReentrant inCompetition(tokenAddress) {
        _sell(tokenAddress, amount, msg.sender, msg.sender);
    }

    function _sell(
        address tokenAddress,
        uint256 amount,
        address from,
        address to
    ) internal returns (uint256) {
        require(
            tokens[tokenAddress] == TokenState.FUNDING,
            "Token is not funding"
        );
        require(amount > 0, "Amount should be greater than zero");
        
        Token token = Token(tokenAddress);
        uint256 _competitionId = competitionIds[tokenAddress];

        uint256 receivedETH = bondingCurve.computeRefundForBurning(
            collateralById[_competitionId][tokenAddress],
            token.totalSupply(),
            amount
        );
        // calculate fee
        uint256 _fee = calculateFee(receivedETH, feePercent);
        receivedETH -= _fee;
        fee += _fee;
        token.burn(from, amount);
        collateralById[_competitionId][tokenAddress] -= receivedETH;
        // send ether
        //slither-disable-next-line arbitrary-send-eth

        if (to != address(this)) {
            (bool success, ) = to.call{value: receivedETH}(new bytes(0));
            require(success, "ETH send failed");
        }

        emit TokenSell(tokenAddress, amount, receivedETH, fee, block.timestamp);

        return receivedETH;
    }

    // Internal functions

    function createLiquilityPool(
        address tokenAddress
    ) internal returns (address) {
        IUniswapV2Factory factory = IUniswapV2Factory(uniswapV2Factory);
        IUniswapV2Router01 router = IUniswapV2Router01(uniswapV2Router);

        address pair = factory.createPair(tokenAddress, router.WETH());
        return pair;
    }

    function addLiquidity(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 ethAmount
    ) internal returns (uint256) {
        Token token = Token(tokenAddress);
        IUniswapV2Router01 router = IUniswapV2Router01(uniswapV2Router);
        token.approve(uniswapV2Router, tokenAmount);
        //slither-disable-next-line arbitrary-send-eth
        (, , uint256 liquidity) = router.addLiquidityETH{value: ethAmount}(
            tokenAddress,
            tokenAmount,
            tokenAmount,
            ethAmount,
            address(this),
            block.timestamp
        );
        return liquidity;
    }

    function burnLiquidityToken(address pair, uint256 liquidity) internal {
        SafeERC20.safeTransfer(IERC20(pair), address(0), liquidity);
    }

    function calculateFee(
        uint256 _amount,
        uint256 _feePercent
    ) internal pure returns (uint256) {
        return (_amount * _feePercent) / FEE_DENOMINATOR;
    }

    function getWinnerByCompetitionId(uint256 competitionId) public view returns (address) {
        uint256 maxCollateral = 0;
        address winnerAddress;

        for (uint256 i = 0; i < tokensByCompetitionId[competitionId].length; i++) {
            address tokenAddress = tokensByCompetitionId[competitionId][i];
            uint256 _collateral = collateralById[competitionId][tokenAddress];

            if (_collateral > maxCollateral) {
                maxCollateral = _collateral;
                winnerAddress = tokenAddress;
            }
        }

        return winnerAddress;
    }

    function setWinnerByCompetitionId(uint256 competitionId) external {
        require(competitionId != currentCompetitionId, 'The competition is still active');

        address winnerAddress = getWinnerByCompetitionId(competitionId);

        if(winners[competitionId] != winnerAddress) {
            winners[competitionId] = winnerAddress;
            emit SetWinner(winnerAddress, competitionId, block.timestamp);
        }
    }

    function burnTokenAndMintWinner(
        address tokenAddress
    ) external nonReentrant {
        uint256 _competitionId = competitionIds[tokenAddress];
        
        require(_competitionId != currentCompetitionId, 'The competition is still active');

        address winnerToken = getWinnerByCompetitionId(_competitionId);

        require(winnerToken != tokenAddress, "token address is the winner");

        Token token = Token(tokenAddress);
        uint256 burnedAmount = token.balanceOf(msg.sender);

        uint256 receivedETH = _sell(
            tokenAddress,
            burnedAmount,
            msg.sender,
            address(this)
        );

        uint256 mintedAmount = _buy(winnerToken, msg.sender, receivedETH);

        emit BurnTokenAndMintWinner(
            msg.sender,
            tokenAddress,
            winnerToken,
            burnedAmount,
            receivedETH,
            mintedAmount,
            block.timestamp
        );
    }
}
