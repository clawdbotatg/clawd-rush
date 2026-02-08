// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@pyth-network/pyth-sdk-solidity/IPyth.sol";
import "@pyth-network/pyth-sdk-solidity/PythStructs.sol";

/// @title CLAWDRush — 1-Minute UP/DOWN Price Prediction Game
/// @notice Bet USDC on ETH or BTC price direction. Win 1.76× payout in $CLAWD.
/// @dev Uses Pyth oracles for pricing, Aerodrome/Uniswap V2 for USDC→CLAWD swaps.
contract CLAWDRush is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Enums ---
    enum Direction { UP, DOWN }

    // --- Structs ---
    struct Bet {
        address player;
        bytes32 asset;        // "ETH" or "BTC" as bytes32
        Direction direction;
        uint256 usdcAmount;   // 6 decimals
        int64 strikePrice;    // Pyth price at bet creation
        int32 strikeExpo;     // Pyth price exponent
        uint64 strikeTime;    // timestamp when bet was placed
        uint64 resolveTime;   // timestamp when bet can be resolved
        bool resolved;
        bool won;
        uint256 clawdPayout;  // CLAWD sent if won
    }

    // --- Constants ---
    uint256 public constant PAYOUT_BPS = 17600; // 1.76× = 17600 basis points (÷10000)
    uint256 public constant MIN_BET = 3e6;      // 3 USDC (6 decimals)
    uint256 public constant MAX_BET = 200e6;    // 200 USDC (6 decimals)
    uint64 public constant RESOLVE_DELAY = 60;  // 1 minute
    uint64 public constant RESOLVE_WINDOW = 3600; // Must resolve within 1 hour
    uint256 public constant MAX_PRICE_AGE = 30; // Price must be within 30 seconds

    // --- Immutables ---
    IERC20 public immutable usdc;
    IERC20 public immutable clawd;
    IPyth public immutable pyth;
    address public immutable dexRouter; // Uniswap V3 SwapRouter
    address public immutable weth;

    // --- State ---
    address public owner;
    uint256 public nextBetId;
    mapping(uint256 => Bet) public bets;
    mapping(address => uint256[]) public playerBets;

    // Pyth price feed IDs
    bytes32 public constant ETH_USD_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 public constant BTC_USD_FEED = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 public constant ETH_ASSET = bytes32("ETH");
    bytes32 public constant BTC_ASSET = bytes32("BTC");

    // --- Events ---
    event BetPlaced(
        uint256 indexed betId,
        address indexed player,
        bytes32 asset,
        Direction direction,
        uint256 usdcAmount,
        int64 strikePrice,
        uint64 resolveTime
    );
    event BetResolved(
        uint256 indexed betId,
        address indexed player,
        bool won,
        int64 finalPrice,
        uint256 clawdPayout
    );
    event HouseFunded(address indexed funder, uint256 amount);
    event HouseWithdrawn(address indexed owner, uint256 amount);

    // --- Errors ---
    error InvalidAsset();
    error BetTooSmall();
    error BetTooLarge();
    error BetAlreadyResolved();
    error TooEarlyToResolve();
    error ResolveWindowExpired();
    error InsufficientHouseFunds();
    error OnlyOwner();
    error SwapFailed();
    error InvalidBetId();

    // --- Modifiers ---
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(
        address _usdc,
        address _clawd,
        address _pyth,
        address _dexRouter,
        address _weth
    ) {
        usdc = IERC20(_usdc);
        clawd = IERC20(_clawd);
        pyth = IPyth(_pyth);
        dexRouter = _dexRouter;
        weth = _weth;
        owner = msg.sender;
    }

    /// @notice Place a bet on price direction
    /// @param asset ETH_ASSET or BTC_ASSET
    /// @param direction UP or DOWN
    /// @param amount USDC amount to bet (6 decimals)
    /// @param priceUpdateData Pyth price update data for current price
    function placeBet(
        bytes32 asset,
        Direction direction,
        uint256 amount,
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant returns (uint256 betId) {
        // Validate asset
        bytes32 feedId = _getFeedId(asset);

        // Validate amount
        if (amount < MIN_BET) revert BetTooSmall();
        if (amount > MAX_BET) revert BetTooLarge();

        // Check house can cover potential payout
        uint256 potentialPayout = (amount * PAYOUT_BPS) / 10000;
        uint256 currentHouseBalance = usdc.balanceOf(address(this));
        // House needs enough USDC to swap for CLAWD (the bet amount + house contribution)
        if (currentHouseBalance + amount < potentialPayout) revert InsufficientHouseFunds();

        // Update Pyth price and get current price
        uint256 pythFee = pyth.getUpdateFee(priceUpdateData);
        pyth.updatePriceFeeds{value: pythFee}(priceUpdateData);

        PythStructs.Price memory currentPrice = pyth.getPriceNoOlderThan(feedId, MAX_PRICE_AGE);

        // Transfer USDC from player
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Create bet
        betId = nextBetId++;
        bets[betId] = Bet({
            player: msg.sender,
            asset: asset,
            direction: direction,
            usdcAmount: amount,
            strikePrice: currentPrice.price,
            strikeExpo: currentPrice.expo,
            strikeTime: uint64(block.timestamp),
            resolveTime: uint64(block.timestamp) + RESOLVE_DELAY,
            resolved: false,
            won: false,
            clawdPayout: 0
        });
        playerBets[msg.sender].push(betId);

        emit BetPlaced(betId, msg.sender, asset, direction, amount, currentPrice.price, uint64(block.timestamp) + RESOLVE_DELAY);

        // Refund excess ETH
        if (msg.value > pythFee) {
            (bool success, ) = msg.sender.call{value: msg.value - pythFee}("");
            require(success, "ETH refund failed");
        }
    }

    /// @notice Resolve a bet after the resolve delay
    /// @param betId The bet to resolve
    /// @param priceUpdateData Pyth price update data for the resolution price
    function resolveBet(
        uint256 betId,
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant {
        if (betId >= nextBetId) revert InvalidBetId();
        Bet storage bet = bets[betId];
        if (bet.resolved) revert BetAlreadyResolved();
        if (block.timestamp < bet.resolveTime) revert TooEarlyToResolve();
        if (block.timestamp > bet.resolveTime + RESOLVE_WINDOW) revert ResolveWindowExpired();

        bytes32 feedId = _getFeedId(bet.asset);

        // Parse the price at resolve time using parsePriceFeedUpdates
        // This gets a historical price without storing it
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = feedId;

        uint256 pythFee = pyth.getUpdateFee(priceUpdateData);
        PythStructs.PriceFeed[] memory feeds = pyth.parsePriceFeedUpdates{value: pythFee}(
            priceUpdateData,
            feedIds,
            bet.resolveTime - 10,      // Allow price from 10s before resolve time
            bet.resolveTime + 30       // Allow price up to 30s after resolve time
        );

        int64 finalPrice = feeds[0].price.price;

        // Determine win/loss
        bool won;
        if (bet.direction == Direction.UP) {
            won = finalPrice > bet.strikePrice;
        } else {
            won = finalPrice < bet.strikePrice;
        }

        bet.resolved = true;
        bet.won = won;

        if (won) {
            // Calculate USDC amount to swap: 1.76× the bet
            uint256 swapAmount = (bet.usdcAmount * PAYOUT_BPS) / 10000;

            // Swap USDC → CLAWD via DEX router
            uint256 clawdBefore = clawd.balanceOf(address(this));
            _swapUSDCForCLAWD(swapAmount);
            uint256 clawdReceived = clawd.balanceOf(address(this)) - clawdBefore;

            bet.clawdPayout = clawdReceived;

            // Transfer CLAWD to winner
            clawd.safeTransfer(bet.player, clawdReceived);
        }
        // If lost, USDC stays in contract (house profit)

        emit BetResolved(betId, bet.player, won, finalPrice, bet.clawdPayout);

        // Refund excess ETH
        if (msg.value > pythFee) {
            (bool success, ) = msg.sender.call{value: msg.value - pythFee}("");
            require(success, "ETH refund failed");
        }
    }

    /// @notice Fund the house with USDC
    function fundHouse(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit HouseFunded(msg.sender, amount);
    }

    /// @notice Withdraw house USDC (owner only)
    function withdrawHouse(uint256 amount) external onlyOwner {
        usdc.safeTransfer(owner, amount);
        emit HouseWithdrawn(owner, amount);
    }

    /// @notice Get player's bet IDs
    function getPlayerBets(address player) external view returns (uint256[] memory) {
        return playerBets[player];
    }

    /// @notice Get multiple bets at once
    function getBets(uint256[] calldata betIds) external view returns (Bet[] memory result) {
        result = new Bet[](betIds.length);
        for (uint256 i = 0; i < betIds.length; i++) {
            result[i] = bets[betIds[i]];
        }
    }

    /// @notice Get house USDC balance
    function houseBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    // --- Internal ---

    function _getFeedId(bytes32 asset) internal pure returns (bytes32) {
        if (asset == ETH_ASSET) return ETH_USD_FEED;
        if (asset == BTC_ASSET) return BTC_USD_FEED;
        revert InvalidAsset();
    }

    function _swapUSDCForCLAWD(uint256 usdcAmount) internal {
        // Approve router to spend USDC
        usdc.forceApprove(dexRouter, usdcAmount);

        // Route: USDC → WETH (V3, 0.05% fee) → CLAWD (V3, 1% fee)
        // Using Uniswap V3 SwapRouter exactInput with multi-hop path
        bytes memory path = abi.encodePacked(
            address(usdc),
            uint24(500),      // 0.05% fee tier USDC/WETH
            weth,
            uint24(10000),    // 1% fee tier WETH/CLAWD
            address(clawd)
        );

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: address(this),
            deadline: block.timestamp + 300,
            amountIn: usdcAmount,
            amountOutMinimum: 0 // Base sequencer provides MEV protection
        });

        ISwapRouter(dexRouter).exactInput(params);
    }

    /// @notice Allow contract to receive ETH (for Pyth fee refunds)
    receive() external payable {}
}

/// @notice Minimal Uniswap V3 SwapRouter interface
interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
