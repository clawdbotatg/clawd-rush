// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/CLAWDRush.sol";
import "@pyth-network/pyth-sdk-solidity/MockPyth.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 dec) ERC20(name, symbol) {
        _decimals = dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

// Mock Aerodrome Router that simulates swaps
contract MockAerodromeRouter {
    MockERC20 public clawd;
    uint256 public clawdPerUsdc; // How many CLAWD per 1 USDC (in CLAWD decimals per USDC decimal)

    constructor(address _clawd, uint256 _rate) {
        clawd = MockERC20(_clawd);
        clawdPerUsdc = _rate;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        IAerodromeRouter.Route[] calldata,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        // Transfer USDC from caller
        IERC20(IAerodromeRouter.Route({from: address(0), to: address(0), stable: false, factory: address(0)}).from);

        // Simple: mint CLAWD to recipient based on rate
        // amountIn is in USDC (6 decimals), output is CLAWD (18 decimals)
        // rate: clawdPerUsdc CLAWD-wei per USDC-wei
        uint256 clawdOut = amountIn * clawdPerUsdc;
        clawd.mint(to, clawdOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = clawdOut;
    }
}

contract CLAWDRushTest is Test {
    CLAWDRush public rush;
    MockPyth public mockPyth;
    MockERC20 public usdc;
    MockERC20 public clawd;
    MockAerodromeRouter public router;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public owner = makeAddr("owner");

    bytes32 constant ETH_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 constant BTC_FEED = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant ETH_ASSET = bytes32("ETH");
    bytes32 constant BTC_ASSET = bytes32("BTC");

    function setUp() public {
        // Deploy mocks
        mockPyth = new MockPyth(60, 1); // 60s validity, 1 wei fee
        usdc = new MockERC20("USD Coin", "USDC", 6);
        clawd = new MockERC20("CLAWD", "CLAWD", 18);

        // Router: 1 USDC = 13,000 CLAWD (roughly $0.000077 per CLAWD)
        // 1e6 USDC-wei * rate = CLAWD-wei
        // rate = 13000 * 1e12 = 13e15 (to account for decimal difference 18-6=12)
        router = new MockAerodromeRouter(address(clawd), 13000 * 1e12);

        // Deploy CLAWDRush
        vm.prank(owner);
        rush = new CLAWDRush(
            address(usdc),
            address(clawd),
            address(mockPyth),
            address(router)
        );

        // Fund alice and bob with ETH and USDC
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 1000e6);

        // Alice approves
        vm.prank(alice);
        usdc.approve(address(rush), type(uint256).max); // Test uses max for simplicity

        vm.prank(bob);
        usdc.approve(address(rush), type(uint256).max);

        // Fund house
        usdc.mint(owner, 10000e6);
        vm.startPrank(owner);
        usdc.approve(address(rush), 10000e6);
        rush.fundHouse(5000e6);
        vm.stopPrank();

        // Set initial ETH price: $3000
        _updatePrice(ETH_FEED, 3000_00000000, -8, block.timestamp);
        // Set initial BTC price: $100000
        _updatePrice(BTC_FEED, 100000_00000000, -8, block.timestamp);
    }

    // --- Helper functions ---

    function _updatePrice(bytes32 feedId, int64 price, int32 expo, uint256 publishTime) internal {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = mockPyth.createPriceFeedUpdateData(
            feedId,
            price,
            10, // conf
            expo,
            price, // ema price
            10,  // ema conf
            uint64(publishTime)
        );
        mockPyth.updatePriceFeeds{value: 1}(updateData);
    }

    function _getPriceUpdateData(bytes32 feedId, int64 price, int32 expo, uint256 publishTime)
        internal view returns (bytes[] memory)
    {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = mockPyth.createPriceFeedUpdateData(
            feedId,
            price,
            10,
            expo,
            price,
            10,
            uint64(publishTime)
        );
        return updateData;
    }

    // --- Tests ---

    function test_placeBet_ETH_UP() public {
        bytes[] memory priceData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);

        vm.prank(alice);
        uint256 betId = rush.placeBet{value: 1}(
            ETH_ASSET,
            CLAWDRush.Direction.UP,
            10e6, // 10 USDC
            priceData
        );

        assertEq(betId, 0);

        (
            address player,
            bytes32 asset,
            CLAWDRush.Direction direction,
            uint256 usdcAmount,
            int64 strikePrice,
            ,
            ,
            uint64 resolveTime,
            bool resolved,
            bool won,
            uint256 clawdPayout
        ) = rush.bets(0);

        assertEq(player, alice);
        assertEq(asset, ETH_ASSET);
        assertEq(uint8(direction), uint8(CLAWDRush.Direction.UP));
        assertEq(usdcAmount, 10e6);
        assertEq(strikePrice, 3000_00000000);
        assertEq(resolveTime, uint64(block.timestamp + 60));
        assertFalse(resolved);
        assertFalse(won);
        assertEq(clawdPayout, 0);
    }

    function test_placeBet_tooSmall() public {
        bytes[] memory priceData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);

        vm.prank(alice);
        vm.expectRevert(CLAWDRush.BetTooSmall.selector);
        rush.placeBet{value: 1}(ETH_ASSET, CLAWDRush.Direction.UP, 2e6, priceData);
    }

    function test_placeBet_tooLarge() public {
        bytes[] memory priceData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);

        vm.prank(alice);
        vm.expectRevert(CLAWDRush.BetTooLarge.selector);
        rush.placeBet{value: 1}(ETH_ASSET, CLAWDRush.Direction.UP, 201e6, priceData);
    }

    function test_placeBet_invalidAsset() public {
        bytes[] memory priceData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);

        vm.prank(alice);
        vm.expectRevert(CLAWDRush.InvalidAsset.selector);
        rush.placeBet{value: 1}(bytes32("DOGE"), CLAWDRush.Direction.UP, 10e6, priceData);
    }

    function test_resolveBet_win_UP() public {
        // Place bet: ETH UP at $3000
        bytes[] memory placeData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);
        vm.prank(alice);
        rush.placeBet{value: 1}(ETH_ASSET, CLAWDRush.Direction.UP, 10e6, placeData);

        // Advance time by 60 seconds
        vm.warp(block.timestamp + 60);

        // ETH went UP to $3100
        bytes[] memory resolveData = _getPriceUpdateData(ETH_FEED, 3100_00000000, -8, block.timestamp);

        uint256 clawdBefore = clawd.balanceOf(alice);
        rush.resolveBet{value: 1}(0, resolveData);
        uint256 clawdAfter = clawd.balanceOf(alice);

        (, , , , , , , , bool resolved, bool won, uint256 payout) = rush.bets(0);
        assertTrue(resolved);
        assertTrue(won);
        assertGt(payout, 0);
        assertEq(clawdAfter - clawdBefore, payout);
    }

    function test_resolveBet_lose_UP() public {
        // Place bet: ETH UP at $3000
        bytes[] memory placeData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);
        vm.prank(alice);
        rush.placeBet{value: 1}(ETH_ASSET, CLAWDRush.Direction.UP, 10e6, placeData);

        vm.warp(block.timestamp + 60);

        // ETH went DOWN to $2900
        bytes[] memory resolveData = _getPriceUpdateData(ETH_FEED, 2900_00000000, -8, block.timestamp);

        uint256 clawdBefore = clawd.balanceOf(alice);
        rush.resolveBet{value: 1}(0, resolveData);
        uint256 clawdAfter = clawd.balanceOf(alice);

        (, , , , , , , , bool resolved, bool won, ) = rush.bets(0);
        assertTrue(resolved);
        assertFalse(won);
        assertEq(clawdAfter, clawdBefore); // No CLAWD received
    }

    function test_resolveBet_win_DOWN() public {
        bytes[] memory placeData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);
        vm.prank(alice);
        rush.placeBet{value: 1}(ETH_ASSET, CLAWDRush.Direction.DOWN, 10e6, placeData);

        vm.warp(block.timestamp + 60);

        // ETH went DOWN to $2900 — player wins
        bytes[] memory resolveData = _getPriceUpdateData(ETH_FEED, 2900_00000000, -8, block.timestamp);

        rush.resolveBet{value: 1}(0, resolveData);

        (, , , , , , , , , bool won, uint256 payout) = rush.bets(0);
        assertTrue(won);
        assertGt(payout, 0);
    }

    function test_resolveBet_tooEarly() public {
        bytes[] memory placeData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);
        vm.prank(alice);
        rush.placeBet{value: 1}(ETH_ASSET, CLAWDRush.Direction.UP, 10e6, placeData);

        // Don't advance time
        bytes[] memory resolveData = _getPriceUpdateData(ETH_FEED, 3100_00000000, -8, block.timestamp);
        vm.expectRevert(CLAWDRush.TooEarlyToResolve.selector);
        rush.resolveBet{value: 1}(0, resolveData);
    }

    function test_resolveBet_doubleResolve() public {
        bytes[] memory placeData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);
        vm.prank(alice);
        rush.placeBet{value: 1}(ETH_ASSET, CLAWDRush.Direction.UP, 10e6, placeData);

        vm.warp(block.timestamp + 60);
        bytes[] memory resolveData = _getPriceUpdateData(ETH_FEED, 3100_00000000, -8, block.timestamp);

        rush.resolveBet{value: 1}(0, resolveData);

        vm.expectRevert(CLAWDRush.BetAlreadyResolved.selector);
        rush.resolveBet{value: 1}(0, resolveData);
    }

    function test_resolveBet_windowExpired() public {
        bytes[] memory placeData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);
        vm.prank(alice);
        rush.placeBet{value: 1}(ETH_ASSET, CLAWDRush.Direction.UP, 10e6, placeData);

        // Advance past resolve window (60s resolve + 3600s window)
        vm.warp(block.timestamp + 3661);
        bytes[] memory resolveData = _getPriceUpdateData(ETH_FEED, 3100_00000000, -8, block.timestamp);

        vm.expectRevert(CLAWDRush.ResolveWindowExpired.selector);
        rush.resolveBet{value: 1}(0, resolveData);
    }

    function test_placeBet_BTC() public {
        bytes[] memory priceData = _getPriceUpdateData(BTC_FEED, 100000_00000000, -8, block.timestamp);

        vm.prank(alice);
        uint256 betId = rush.placeBet{value: 1}(BTC_ASSET, CLAWDRush.Direction.DOWN, 50e6, priceData);

        (, bytes32 asset, , uint256 amount, int64 strikePrice, , , , , , ) = rush.bets(betId);
        assertEq(asset, BTC_ASSET);
        assertEq(amount, 50e6);
        assertEq(strikePrice, 100000_00000000);
    }

    function test_fundHouse() public {
        uint256 balBefore = rush.houseBalance();
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(rush), 100e6);
        rush.fundHouse(100e6);
        vm.stopPrank();
        assertEq(rush.houseBalance(), balBefore + 100e6);
    }

    function test_withdrawHouse() public {
        uint256 ownerBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        rush.withdrawHouse(100e6);
        assertEq(usdc.balanceOf(owner), ownerBefore + 100e6);
    }

    function test_withdrawHouse_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(CLAWDRush.OnlyOwner.selector);
        rush.withdrawHouse(100e6);
    }

    function test_getPlayerBets() public {
        bytes[] memory priceData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);

        vm.prank(alice);
        rush.placeBet{value: 1}(ETH_ASSET, CLAWDRush.Direction.UP, 5e6, priceData);

        _updatePrice(ETH_FEED, 3000_00000000, -8, block.timestamp + 1);
        priceData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp + 1);

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        rush.placeBet{value: 1}(ETH_ASSET, CLAWDRush.Direction.DOWN, 10e6, priceData);

        uint256[] memory bets = rush.getPlayerBets(alice);
        assertEq(bets.length, 2);
        assertEq(bets[0], 0);
        assertEq(bets[1], 1);
    }

    function test_priceUnchanged_isLoss() public {
        bytes[] memory placeData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);
        vm.prank(alice);
        rush.placeBet{value: 1}(ETH_ASSET, CLAWDRush.Direction.UP, 10e6, placeData);

        vm.warp(block.timestamp + 60);

        // Price unchanged — should be a loss
        bytes[] memory resolveData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);
        rush.resolveBet{value: 1}(0, resolveData);

        (, , , , , , , , , bool won, ) = rush.bets(0);
        assertFalse(won);
    }

    function test_invalidBetId() public {
        bytes[] memory resolveData = _getPriceUpdateData(ETH_FEED, 3000_00000000, -8, block.timestamp);
        vm.expectRevert(CLAWDRush.InvalidBetId.selector);
        rush.resolveBet{value: 1}(999, resolveData);
    }
}
