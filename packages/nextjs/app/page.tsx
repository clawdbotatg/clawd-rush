"use client";

import { useState, useEffect } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { useScaffoldContract } from "~~/hooks/scaffold-eth";
import { formatUnits, parseUnits } from "viem";
import { notification } from "~~/utils/scaffold-eth";

const PYTH_HERMES_URL = "https://hermes.pyth.network";
const ETH_FEED_ID = "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace";
const BTC_FEED_ID = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43";
const ETH_ASSET = "0x4554480000000000000000000000000000000000000000000000000000000000" as `0x${string}`;
const BTC_ASSET = "0x4254430000000000000000000000000000000000000000000000000000000000" as `0x${string}`;

interface BetInfo {
  betId: bigint;
  player: string;
  asset: string;
  direction: number;
  usdcAmount: bigint;
  strikePrice: bigint;
  strikeExpo: number;
  strikeTime: bigint;
  resolveTime: bigint;
  resolved: boolean;
  won: boolean;
  clawdPayout: bigint;
}

const formatPrice = (price: bigint, expo: number): string => {
  const priceNum = Number(price) * Math.pow(10, expo);
  return priceNum.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
};

const Home: NextPage = () => {
  const { address: connectedAddress, isConnected, chain } = useAccount();
  const [selectedAsset, setSelectedAsset] = useState<"ETH" | "BTC">("ETH");
  const [betAmount, setBetAmount] = useState("10");
  const [livePrice, setLivePrice] = useState<{ eth: number; btc: number }>({ eth: 0, btc: 0 });
  const [isPlacingBet, setIsPlacingBet] = useState(false);
  const [isApproving, setIsApproving] = useState(false);
  const [isResolving, setIsResolving] = useState<Record<string, boolean>>({});
  const [playerBetIds, setPlayerBetIds] = useState<bigint[]>([]);
  const [playerBets, setPlayerBets] = useState<BetInfo[]>([]);
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));

  const isBase = chain?.id === 8453 || chain?.id === 31337;

  // Contract reads
  const { data: rushContract } = useScaffoldContract({ contractName: "CLAWDRush" });

  const { data: usdcAllowance, refetch: refetchAllowance } = useScaffoldReadContract({
    contractName: "USDC",
    functionName: "allowance",
    args: [connectedAddress, rushContract?.address],
  });

  const { data: usdcBalance } = useScaffoldReadContract({
    contractName: "USDC",
    functionName: "balanceOf",
    args: [connectedAddress],
  });

  const { data: clawdBalance } = useScaffoldReadContract({
    contractName: "CLAWD",
    functionName: "balanceOf",
    args: [connectedAddress],
  });

  const { data: houseBalance } = useScaffoldReadContract({
    contractName: "CLAWDRush",
    functionName: "houseBalance",
  });

  const { data: betIdsRaw } = useScaffoldReadContract({
    contractName: "CLAWDRush",
    functionName: "getPlayerBets",
    args: [connectedAddress],
  });

  // Contract writes
  const { writeContractAsync: writeRush } = useScaffoldWriteContract("CLAWDRush");
  const { writeContractAsync: writeUsdc } = useScaffoldWriteContract("USDC");

  // Fetch live prices from Pyth
  useEffect(() => {
    const fetchPrices = async () => {
      try {
        const res = await fetch(
          `${PYTH_HERMES_URL}/v2/updates/price/latest?ids[]=${ETH_FEED_ID}&ids[]=${BTC_FEED_ID}`
        );
        const data = await res.json();
        if (data.parsed) {
          for (const feed of data.parsed) {
            const price = Number(feed.price.price) * Math.pow(10, feed.price.expo);
            if (feed.id === ETH_FEED_ID.slice(2)) {
              setLivePrice(prev => ({ ...prev, eth: price }));
            } else if (feed.id === BTC_FEED_ID.slice(2)) {
              setLivePrice(prev => ({ ...prev, btc: price }));
            }
          }
        }
      } catch (e) {
        console.error("Failed to fetch Pyth prices:", e);
      }
    };

    fetchPrices();
    const interval = setInterval(fetchPrices, 3000);
    return () => clearInterval(interval);
  }, []);

  // Timer update
  useEffect(() => {
    const interval = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(interval);
  }, []);

  // Fetch player bets
  useEffect(() => {
    if (betIdsRaw) {
      setPlayerBetIds([...(betIdsRaw as bigint[])]);
    }
  }, [betIdsRaw]);

  // Fetch bet details
  useEffect(() => {
    const fetchBets = async () => {
      if (!rushContract || playerBetIds.length === 0) return;
      // We'll read individual bets
      const bets: BetInfo[] = [];
      for (const id of playerBetIds.slice(-10)) { // Last 10 bets
        try {
          const result = await rushContract.read.bets([id]) as any;
          bets.push({
            betId: id,
            player: result[0],
            asset: result[1],
            direction: Number(result[2]),
            usdcAmount: result[3],
            strikePrice: result[4],
            strikeExpo: Number(result[5]),
            strikeTime: result[6],
            resolveTime: result[7],
            resolved: result[8],
            won: result[9],
            clawdPayout: result[10],
          });
        } catch (e) {
          console.error("Failed to read bet", id, e);
        }
      }
      setPlayerBets(bets.reverse());
    };

    fetchBets();
    const interval = setInterval(fetchBets, 5000);
    return () => clearInterval(interval);
  }, [rushContract, playerBetIds]);

  const betAmountWei = parseUnits(betAmount || "0", 6);
  const needsApproval = !usdcAllowance || usdcAllowance < betAmountWei;

  // Fetch Pyth price update data
  const fetchPriceUpdateData = async (): Promise<`0x${string}`[]> => {
    const feedId = selectedAsset === "ETH" ? ETH_FEED_ID : BTC_FEED_ID;
    const res = await fetch(`${PYTH_HERMES_URL}/v2/updates/price/latest?ids[]=${feedId}`);
    const data = await res.json();
    return data.binary.data.map((d: string) => `0x${d}` as `0x${string}`);
  };

  // Fetch Pyth price at a specific timestamp for resolution
  const fetchResolvePriceData = async (timestamp: number, feedId: string): Promise<`0x${string}`[]> => {
    const res = await fetch(
      `${PYTH_HERMES_URL}/v2/updates/price/${timestamp}?ids[]=${feedId}`
    );
    const data = await res.json();
    return data.binary.data.map((d: string) => `0x${d}` as `0x${string}`);
  };

  const handleApprove = async () => {
    setIsApproving(true);
    try {
      await writeUsdc({
        functionName: "approve",
        args: [rushContract?.address, betAmountWei],
      });
      await refetchAllowance();
      notification.success("USDC approved!");
    } catch (e: any) {
      console.error(e);
      notification.error("Approval failed");
    } finally {
      setIsApproving(false);
    }
  };

  const handlePlaceBet = async (direction: 0 | 1) => {
    setIsPlacingBet(true);
    try {
      const priceData = await fetchPriceUpdateData();
      const asset = selectedAsset === "ETH" ? ETH_ASSET : BTC_ASSET;

      await writeRush({
        functionName: "placeBet",
        args: [asset, direction, betAmountWei, priceData],
        value: BigInt(2), // Small ETH for Pyth fee
      });
      notification.success(`${direction === 0 ? "UP" : "DOWN"} bet placed! ⏱`);
    } catch (e: any) {
      console.error(e);
      notification.error("Failed to place bet");
    } finally {
      setIsPlacingBet(false);
    }
  };

  const handleResolve = async (bet: BetInfo) => {
    const key = bet.betId.toString();
    setIsResolving(prev => ({ ...prev, [key]: true }));
    try {
      const feedId = bet.asset === ETH_ASSET ? ETH_FEED_ID : BTC_FEED_ID;
      const resolveTimestamp = Number(bet.resolveTime);
      const priceData = await fetchResolvePriceData(resolveTimestamp, feedId);

      await writeRush({
        functionName: "resolveBet",
        args: [bet.betId, priceData],
        value: BigInt(2),
      });
      notification.success("Bet resolved! Check result below.");
    } catch (e: any) {
      console.error(e);
      notification.error("Failed to resolve bet");
    } finally {
      setIsResolving(prev => ({ ...prev, [key]: false }));
    }
  };

  const currentPrice = selectedAsset === "ETH" ? livePrice.eth : livePrice.btc;
  const betAmountUsd = parseFloat(betAmount || "0");
  const potentialWin = (betAmountUsd * 1.76).toFixed(2);

  return (
    <div className="flex flex-col items-center min-h-screen bg-base-300 pt-6 px-4">
      {/* Game Panel */}
      <div className="w-full max-w-md">
        {/* Asset Selector + Price */}
        <div className="bg-base-100 rounded-2xl p-6 mb-4 shadow-xl border border-base-content/10">
          <div className="flex justify-center gap-2 mb-4">
            <button
              className={`btn btn-sm ${selectedAsset === "ETH" ? "btn-primary" : "btn-ghost"}`}
              onClick={() => setSelectedAsset("ETH")}
            >
              Ξ ETH
            </button>
            <button
              className={`btn btn-sm ${selectedAsset === "BTC" ? "btn-primary" : "btn-ghost"}`}
              onClick={() => setSelectedAsset("BTC")}
            >
              ₿ BTC
            </button>
          </div>

          <div className="text-center mb-2">
            <div className="text-sm opacity-60">{selectedAsset}/USD</div>
            <div className="text-4xl font-bold font-mono">
              ${currentPrice > 0 ? currentPrice.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : "Loading..."}
            </div>
            <div className="text-xs opacity-40 mt-1">Pyth Oracle · Live</div>
          </div>
        </div>

        {/* Bet Input */}
        <div className="bg-base-100 rounded-2xl p-6 mb-4 shadow-xl border border-base-content/10">
          <label className="text-sm opacity-60 mb-2 block">Bet Amount (USDC)</label>
          <div className="flex gap-2 mb-2">
            {[5, 10, 25, 50, 100].map(amt => (
              <button
                key={amt}
                className={`btn btn-xs ${betAmount === String(amt) ? "btn-primary" : "btn-outline"}`}
                onClick={() => setBetAmount(String(amt))}
              >
                ${amt}
              </button>
            ))}
          </div>
          <input
            type="number"
            className="input input-bordered w-full text-xl font-mono"
            value={betAmount}
            onChange={e => setBetAmount(e.target.value)}
            min="3"
            max="200"
            placeholder="Enter amount..."
          />
          <div className="flex justify-between text-xs mt-2 opacity-60">
            <span>Min: $3 · Max: $200</span>
            <span>Balance: {usdcBalance ? formatUnits(usdcBalance, 6) : "0"} USDC</span>
          </div>
          {betAmountUsd > 0 && (
            <div className="text-center mt-3 text-sm">
              Win → <span className="text-success font-bold">${potentialWin} in $CLAWD</span>
              <span className="text-xs opacity-40 ml-1">(1.76×)</span>
            </div>
          )}
        </div>

        {/* Action Buttons */}
        <div className="bg-base-100 rounded-2xl p-6 mb-4 shadow-xl border border-base-content/10">
          {!isConnected ? (
            <div className="text-center">
              <p className="mb-3 opacity-60">Connect your wallet to play</p>
              {/* RainbowKit connect button is in header — but we show a prompt here */}
              <button className="btn btn-primary btn-lg w-full" onClick={() => {
                // Trigger the RainbowKit modal
                document.querySelector<HTMLButtonElement>('[data-testid="rk-connect-button"]')?.click();
              }}>
                🔗 Connect Wallet
              </button>
            </div>
          ) : !isBase ? (
            <button className="btn btn-warning btn-lg w-full" onClick={() => {
              // Switch network
              document.querySelector<HTMLButtonElement>('[data-testid="rk-chain-button"]')?.click();
            }}>
              ⚠️ Switch to Base
            </button>
          ) : needsApproval ? (
            <button
              className="btn btn-primary btn-lg w-full"
              disabled={isApproving || betAmountUsd < 3}
              onClick={handleApprove}
            >
              {isApproving ? (
                <><span className="loading loading-spinner loading-sm"></span> Approving...</>
              ) : (
                `Approve ${betAmount} USDC`
              )}
            </button>
          ) : (
            <div className="flex gap-3">
              <button
                className="btn btn-lg flex-1 bg-green-600 hover:bg-green-700 text-white border-none"
                disabled={isPlacingBet || betAmountUsd < 3 || betAmountUsd > 200}
                onClick={() => handlePlaceBet(0)}
              >
                {isPlacingBet ? (
                  <><span className="loading loading-spinner loading-sm"></span> Placing...</>
                ) : (
                  "🟢 UP"
                )}
              </button>
              <button
                className="btn btn-lg flex-1 bg-red-600 hover:bg-red-700 text-white border-none"
                disabled={isPlacingBet || betAmountUsd < 3 || betAmountUsd > 200}
                onClick={() => handlePlaceBet(1)}
              >
                {isPlacingBet ? (
                  <><span className="loading loading-spinner loading-sm"></span> Placing...</>
                ) : (
                  "🔴 DOWN"
                )}
              </button>
            </div>
          )}
        </div>

        {/* Balances */}
        {isConnected && (
          <div className="bg-base-100 rounded-2xl p-4 mb-4 shadow-xl border border-base-content/10">
            <div className="flex justify-between text-sm">
              <span className="opacity-60">Your CLAWD:</span>
              <span className="font-mono">{clawdBalance ? Number(formatUnits(clawdBalance, 18)).toLocaleString() : "0"}</span>
            </div>
            <div className="flex justify-between text-sm mt-1">
              <span className="opacity-60">House Pool:</span>
              <span className="font-mono">{houseBalance ? formatUnits(houseBalance, 6) : "0"} USDC</span>
            </div>
          </div>
        )}

        {/* Active Bets & History */}
        {playerBets.length > 0 && (
          <div className="bg-base-100 rounded-2xl p-4 mb-4 shadow-xl border border-base-content/10">
            <h3 className="font-bold mb-3">Your Bets</h3>
            <div className="space-y-3">
              {playerBets.map(bet => {
                const assetName = bet.asset === ETH_ASSET ? "ETH" : "BTC";
                const dirLabel = bet.direction === 0 ? "🟢 UP" : "🔴 DOWN";
                const amount = formatUnits(bet.usdcAmount, 6);
                const strike = formatPrice(bet.strikePrice, bet.strikeExpo);
                const resolveTime = Number(bet.resolveTime);
                const timeLeft = resolveTime - now;
                const canResolve = !bet.resolved && now >= resolveTime;
                const resolveKey = bet.betId.toString();

                return (
                  <div key={bet.betId.toString()} className={`p-3 rounded-xl border ${
                    bet.resolved
                      ? bet.won
                        ? "border-success/30 bg-success/5"
                        : "border-error/30 bg-error/5"
                      : "border-base-content/10"
                  }`}>
                    <div className="flex justify-between items-center">
                      <div>
                        <span className="font-bold">{assetName}</span>
                        <span className="ml-2">{dirLabel}</span>
                        <span className="ml-2 font-mono">${amount}</span>
                      </div>
                      <div className="text-sm">
                        {bet.resolved ? (
                          bet.won ? (
                            <span className="text-success font-bold">
                              🎉 Won {Number(formatUnits(bet.clawdPayout, 18)).toLocaleString()} CLAWD
                            </span>
                          ) : (
                            <span className="text-error">Lost</span>
                          )
                        ) : canResolve ? (
                          <button
                            className="btn btn-sm btn-primary"
                            disabled={isResolving[resolveKey]}
                            onClick={() => handleResolve(bet)}
                          >
                            {isResolving[resolveKey] ? (
                              <><span className="loading loading-spinner loading-xs"></span> Resolving</>
                            ) : (
                              "⚡ Resolve"
                            )}
                          </button>
                        ) : (
                          <span className="font-mono text-warning">
                            ⏱ {timeLeft > 0 ? `${timeLeft}s` : "Ready..."}
                          </span>
                        )}
                      </div>
                    </div>
                    <div className="text-xs opacity-40 mt-1">
                      Strike: ${strike}
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {/* How It Works */}
        <div className="bg-base-100 rounded-2xl p-4 mb-8 shadow-xl border border-base-content/10 opacity-70">
          <h3 className="font-bold mb-2">How It Works</h3>
          <ol className="text-sm space-y-1 list-decimal list-inside">
            <li>Pick ETH or BTC</li>
            <li>Choose your bet amount in USDC</li>
            <li>Hit UP 🟢 or DOWN 🔴</li>
            <li>Wait 60 seconds ⏱</li>
            <li>Resolve — if price moved your way, win 1.76× in $CLAWD! 🎉</li>
          </ol>
          <p className="text-xs mt-2 opacity-50">Powered by Pyth oracles · Payouts via Aerodrome DEX</p>
        </div>
      </div>
    </div>
  );
};

export default Home;
