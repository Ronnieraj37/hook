"use client";

import { ArrowLeftRight, Bot, FlaskConical, Layers, LineChart, ShieldCheck, Sparkles, Target } from "lucide-react";
import Link from "next/link";
import { CORE, POOLS, TOKENS } from "@/lib/pools";
import { Callout, Cards, Code, Dev, Kbd, Section, Steps } from "./ui";
import { Architecture, BitMap, Decoder, RangeSides } from "./visuals";

const ES = "https://sepolia.etherscan.io/address/";
const A = ({ a }: { a: string }) => (
  <a href={`${ES}${a}`} target="_blank" rel="noreferrer" className="font-mono text-[12.5px]">
    {a.slice(0, 6)}…{a.slice(-4)}
  </a>
);

export type DocSection = { id: string; title: string; group: "guide" | "dev"; keywords: string; render: () => React.ReactNode };

export const SECTIONS: DocSection[] = [
  // ================================================================ guide
  {
    id: "overview",
    title: "What Alucard does",
    group: "guide",
    keywords: "intro overview hook uniswap v4 rules automate",
    render: () => (
      <Section id="overview" title="What Alucard does" lead="Uniswap liquidity that follows your rules, plus limit orders. Your money stays in Uniswap the whole time.">
        <p>
          Providing liquidity on Uniswap means watching the price: when it leaves your range you stop earning, and you have to decide whether to withdraw,
          move the range or swap. Alucard lets you write those decisions down once, as <strong>rules</strong>, when you add liquidity. When a rule’s moment
          comes, it runs on its own.
        </p>
        <Cards
          items={[
            { icon: Sparkles, title: "Rules on your liquidity", text: "Take profit, stop loss, follow the price, compound fees. Optional, and editable later.", href: "#rules" },
            { icon: Target, title: "Limit orders", text: "Sell at a price you choose. Filled inside other people’s swaps.", href: "#limit-orders" },
            { icon: FlaskConical, title: "Backtests", text: "Replay six months of real swaps against your rules before you commit.", href: "#backtest" },
            { icon: Bot, title: "Anyone can run a rule", text: "No company in the middle. Whoever runs a rule gets its gas back from the position.", href: "#keepers" },
          ]}
        />
        <Callout kind="warn" title="Testnet">
          Alucard runs on Ethereum Sepolia with test tokens (tWETH, tUSDC…) that anyone can mint. They have no value.
        </Callout>
        <Dev>
          <p>
            Two contracts. <code>RuleHook</code> is a Uniswap v4 hook (afterInitialize, beforeSwap, afterSwap): it keeps a pool table and the limit-order
            buckets. <code>ConditionalOrders</code> owns positions that have rules, inside the PoolManager (owner = the contract, salt = order id). Two because
            one contract was over the 24 KB size limit Unichain still enforces. Source: <code>src/</code>, tests: <code>test/</code> (60 Foundry tests).
          </p>
        </Dev>
      </Section>
    ),
  },
  {
    id: "getting-started",
    title: "Getting started",
    group: "guide",
    keywords: "wallet connect sepolia faucet test tokens metamask",
    render: () => (
      <Section id="getting-started" title="Getting started" lead="Three minutes from zero to your first position.">
        <Steps
          items={[
            <>
              <strong>Connect a wallet</strong> (MetaMask or any browser wallet) with <Kbd>Connect</Kbd>. If it is on another network, the app offers to switch to
              Sepolia.
            </>,
            <>
              <strong>Get Sepolia ETH</strong> for gas from any public Sepolia faucet. Gas on Sepolia costs a tiny fraction of a cent.
            </>,
            <>
              <strong>Get test tokens</strong> with <Kbd>Faucet</Kbd> in the header: one transaction gives 100 tWETH, 5 tWBTC, 500,000 tUSDC, tUSDT and tDAI, and
              20,000 tLINK.
            </>,
            <>
              <strong>Try it</strong>: <Link href="/swap">swap</Link>, place a <Link href="/swap">limit order</Link>, or <Link href="/pool/new">add liquidity</Link> with a
              rule.
            </>,
          ]}
        />
        <Dev>
          <p>
            The faucet is <code>TestFaucet.drip()</code> at <A a={CORE.faucet} />. It calls <code>mint(msg.sender, amount)</code> on each open-mint{" "}
            <code>TestToken</code>, so it works with any wallet (no batching support needed).
          </p>
        </Dev>
      </Section>
    ),
  },
  {
    id: "swap",
    title: "Swapping",
    group: "guide",
    keywords: "swap trade quote route slippage",
    render: () => (
      <Section id="swap" title="Swapping" lead="Trade between test tokens in Alucard’s pools.">
        <p>
          Type an amount and the app asks Uniswap’s quoter for the best price across the pools of that pair. When a pair has more than one pool you can pick
          the route; swaps in pools that use Alucard’s hook also fill limit orders and can trigger rules. Swaps accept up to 0.5% slippage.
        </p>
        <Dev>
          <p>
            Quotes: Uniswap v4 <code>V4Quoter.quoteExactInputSingle</code> via <code>eth_call</code> (the quoter is not a view function). Swaps: hookmate
            router <code>swapExactTokensForTokens(amountIn, amountOutMin, zeroForOne, poolKey, hookData, receiver, deadline)</code> at <A a={CORE.swapRouter} />.
          </p>
        </Dev>
      </Section>
    ),
  },
  {
    id: "limit-orders",
    title: "Limit orders",
    group: "guide",
    keywords: "limit order sell price bucket fill claim cancel",
    render: () => (
      <Section id="limit-orders" title="Limit orders" lead="Sell a token when its price reaches a level you choose.">
        <Steps
          items={[
            <>
              On <Link href="/swap">Swap</Link>, switch to <Kbd>Limit</Kbd>, choose what to sell and the price (or tap +1%, +2%, +5%, +10%).
            </>,
            <>The app shows the exact price band your order sells in: one tick spacing, about 0.6% wide in a 0.3% pool.</>,
            <>When someone’s swap moves the price all the way through that band, your order is filled during their swap.</>,
            <>
              Claim the proceeds under <em>Your limit orders</em>. Until it fills you can cancel at any time.
            </>,
          ]}
        />
        <Callout kind="note">
          While the price is inside your band, your order is partly sold and earns pool fees. If the price turns back before crossing the whole band, the
          sale reverses. Only a full cross locks it in.
        </Callout>
        <Callout kind="tip" title="Very small orders">
          Orders below 0.01% of the pool’s active liquidity are not filled inside swaps (so nobody can spam swappers with dust). Once crossed, anyone can fill
          them; in pools with native ETH the filler is paid back its gas from the order’s proceeds.
        </Callout>
        <Dev>
          <p>
            Orders at the same price share one Uniswap position (a <em>bucket</em>: range <code>[tickLower, tickLower + spacing]</code>, salt{" "}
            <code>2^255 | epochId</code>). <code>afterSwap</code> walks the hook’s own tick bitmap between the ticks before and after the swap and removes every
            fully crossed bucket in one <code>modifyLiquidity</code>, keeping proceeds as ERC-6909 claims. Details in{" "}
            <a href="#limit-internals">Limit order internals</a>.
          </p>
        </Dev>
      </Section>
    ),
  },
  {
    id: "positions",
    title: "Adding liquidity",
    group: "guide",
    keywords: "add liquidity position range deposit nft plain",
    render: () => (
      <Section id="positions" title="Adding liquidity" lead="A normal Uniswap position, with optional rules.">
        <Steps
          items={[
            <>
              <Link href="/pool/new">New position</Link>: pick a pair and fee tier.
            </>,
            <>Set a range with a preset (±2%, ±5%, ±15%, full) or type the low and high price.</>,
            <>Type one amount; the other is filled in from the price and the range.</>,
            <>
              Leave <Kbd>Automate with rules</Kbd> off for a plain Uniswap position, or turn it on to add rules.
            </>,
          ]}
        />
        <p>
          Plain positions are ordinary Uniswap NFTs in your wallet. Positions with rules are held by the Alucard contract for you; you can edit their rules or
          withdraw everything at any time from <Link href="/pool">Pool</Link>.
        </p>
        <Dev>
          <p>
            No rules: <code>PositionManager.modifyLiquidities</code> with <code>MINT_POSITION, SETTLE_PAIR, SWEEP</code> through Permit2. With rules:{" "}
            <code>ConditionalOrders.createOrder(CreateParams)</code>, where the app sends liquidity plus <code>amount0Max/amount1Max</code> with 2% headroom.
          </p>
        </Dev>
      </Section>
    ),
  },
  {
    id: "rules",
    title: "Rules",
    group: "guide",
    keywords: "rules trigger steps repeat side lower upper template take profit stop loss follow compound",
    render: () => (
      <Section id="rules" title="Rules" lead="Each position has two sides. Each side is: when this happens, do these steps, then stop or repeat.">
        <RangeSides />
        <h3>Triggers: when</h3>
        <table>
          <thead>
            <tr>
              <th>Trigger</th>
              <th>Fires when</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Price leaves my range</td>
              <td>The price moves past your range’s edge, optionally by an extra margin (e.g. 1% past it).</td>
            </tr>
            <tr>
              <td>Price reaches a level</td>
              <td>The pool’s price drops below (lower side) or rises above (upper side) a price you choose.</td>
            </tr>
            <tr>
              <td>Price in another pool</td>
              <td>The same, but watching another pool’s price (a bigger pool, or another pair).</td>
            </tr>
            <tr>
              <td>On a timer</td>
              <td>A fixed time has passed since it last ran: every few hours or days.</td>
            </tr>
          </tbody>
        </table>
        <h3>Steps: what to do</h3>
        <table>
          <thead>
            <tr>
              <th>Step</th>
              <th>Effect</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Withdraw</td>
              <td>Take some or all of the liquidity out to your wallet.</td>
            </tr>
            <tr>
              <td>Convert to one token</td>
              <td>Swap what was withdrawn into one token at once, never worse than your slippage limit.</td>
            </tr>
            <tr>
              <td>Follow the price</td>
              <td>Move the whole position to a new range right next to the price.</td>
            </tr>
            <tr>
              <td>Compound</td>
              <td>Put earned fees back into the same range.</td>
            </tr>
            <tr>
              <td>Send fees to wallet</td>
              <td>Fees go to you instead of staying in the position.</td>
            </tr>
          </tbody>
        </table>
        <h3>Templates</h3>
        <p>
          <strong>Take profit</strong>, <strong>Stop loss</strong> (exit to the stable token), <strong>Auto re-range</strong>, <strong>Auto-compound</strong> and{" "}
          <strong>Exit both ways</strong> fill the canvas in one click. Everything stays editable.
        </p>
        <Callout kind="note" title="A few combinations are not allowed (yet)">
          <ul className="!my-1">
            <li>Convert and re-add together (swapping to the right ratio before re-adding comes later).</li>
            <li>Follow the price needs the “leaves my range” trigger.</li>
            <li>Repeating “leaves my range” without moving the range would fire again at once, so it needs Follow the price.</li>
            <li>A repeating price level moves its trigger by a step you set after each run.</li>
          </ul>
          The editor warns before you save.
        </Callout>
        <p>
          Rules expire (30 days by default; set under Advanced). When both sides have run and are off, the position closes and everything goes to your wallet.
        </p>
        <Dev>
          <p>
            In storage a side is 128 bits; the UI’s “falls/rises” lanes map to the contract’s lower/upper halves through the pool’s token order. See{" "}
            <a href="#storage">Order storage</a> and <a href="#encoding">Encoding a rule</a>.
          </p>
        </Dev>
      </Section>
    ),
  },
  {
    id: "keepers",
    title: "Who runs the rules",
    group: "guide",
    keywords: "keeper execute gas refund fee bot",
    render: () => (
      <Section id="keepers" title="Who runs the rules" lead="A blockchain does nothing by itself: someone has to send the transaction.">
        <p>
          Anyone can run a rule whose condition is met. The contract checks the condition again, runs the steps, and pays the caller back their gas from the
          position (with a 10% premium), never from your wallet. You set a ceiling on that pay (0.1% of what a run moves, by default; at most 1%). In pools
          without native ETH, gas cannot be priced in the pool’s tokens yet, so the keeper takes that ceiling.
        </p>
        <p>
          Alucard runs a keeper bot every few minutes, and the <Link href="/keeper">Keeper</Link> page lets anyone run ready rules by hand.
        </p>
        <Dev>
          <p>Keeper pay, measured inside the unlock callback so the gas limit a keeper picks cannot inflate it:</p>
          <Code lang="solidity">{`keeperGasCost(gasUsed) = (gasUsed + 60_000) * min(tx.gasprice, block.basefee + 0.01 gwei) * 110%
reserve               = maxKeeperFeeBps * (tokens the run removed)        // set aside before re-adding
native-ETH pools      : keeper gets min(cost, reserve); the rest goes to the owner
ERC20-only pools      : keeper gets the whole reserve (gas cannot be priced in those tokens yet)`}</Code>
          <p>
            Bot: <code>frontend/scripts/keeper.ts</code>, scheduled by <code>.github/workflows/keeper.yml</code>. It re-simulates each <code>execute</code>{" "}
            before sending, so it never pays for a run that would revert.
          </p>
        </Dev>
      </Section>
    ),
  },
  {
    id: "backtest",
    title: "Backtesting",
    group: "guide",
    keywords: "backtest history replay results windows",
    render: () => (
      <Section id="backtest" title="Backtesting" lead="See how your rules would have done on real history before you use them.">
        <p>
          In the rule editor, press <Kbd>Backtest</Kbd>. Every recorded swap of Ethereum’s ETH/USDC pools (5 April to 3 October 2026: 96 thousand swaps in the
          0.30% pool, 1 million in the 0.05% pool) is replayed against your position and rules, the way the contract would run them.
        </p>
        <ul>
          <li>
            <strong>Compared with:</strong> the same position without rules, and simply holding the tokens.
          </li>
          <li>
            <strong>Every 30-day window</strong> repeats the test from each week’s start, so one lucky or unlucky period cannot mislead you.
          </li>
          <li>
            <strong>Costs counted:</strong> keeper pay (Unichain or Ethereum gas), swap fees and price impact of conversions, your fee ceiling.
          </li>
        </ul>
        <Callout kind="warn" title="What a backtest cannot tell you">
          The past does not predict the future. Your own conversions do not move later prices in the replay, and price manipulation and MEV are not modelled.
          For pairs other than ETH/USDC, the test uses ETH’s price path with your range and triggers scaled to it.
        </Callout>
        <Dev>
          <p>
            Runs on the server, not in your browser: see <a href="#backtest-api">Backtest API</a>.
          </p>
        </Dev>
      </Section>
    ),
  },
  {
    id: "safety",
    title: "Safety and limits",
    group: "guide",
    keywords: "safety security manipulation flash loan slippage expiry payout withdraw",
    render: () => (
      <Section id="safety" title="Safety and limits" lead="What protects your position, and what to be aware of.">
        <Cards
          items={[
            { icon: ShieldCheck, title: "No flash-loan triggers", text: "A rule cannot run right after a swap in the same transaction, so nobody can borrow money to push the price and fire it." },
            { icon: ArrowLeftRight, title: "Slippage from the trigger price", text: "Conversions never sell worse than your slippage limit measured from the trigger price, however far someone pushes the price." },
            { icon: Layers, title: "Payouts are never stuck", text: "If a transfer to you fails (e.g. a contract wallet that refuses ETH), it is held for you to withdraw to any address." },
            { icon: LineChart, title: "Always yours", text: "Withdraw everything at any time. After expiry anyone can close it, and the tokens still go to you." },
          ]}
        />
        <Callout kind="warn">
          Not audited. No admin key and no upgrades: if a bug were found, you would withdraw and move to a new version. Testnet only.
        </Callout>
        <Dev>
          <p>
            Flash-loan guard: <code>RuleHook._beforeSwap</code> sets a transient flag at <code>keccak256(abi.encode(poolId, SWAPPED_TAG))</code>;{" "}
            <code>execute</code> reverts with <code>SwappedThisTx</code> if the order’s pool (or the pool a TICK side watches) is flagged. Pools without the hook
            are never flagged, so a cross-pool trigger on a hookless pool is protected only by the slippage limit.
          </p>
        </Dev>
      </Section>
    ),
  },
  {
    id: "faq",
    title: "FAQ",
    group: "guide",
    keywords: "faq questions",
    render: () => (
      <Section id="faq" title="FAQ">
        <h3>Can I attach rules to a position I already have?</h3>
        <p>Not yet. A position gets rules when it is created through Alucard. You can withdraw a plain position and create a new one with rules.</p>
        <h3>What happens if nobody runs my rule?</h3>
        <p>
          It stays ready. When it runs later, the contract checks the condition again at that moment; if the price has moved back, it simply does not run.
        </p>
        <h3>Can I change my rules?</h3>
        <p>
          Yes. Open the position under <Link href="/pool">Pool</Link> and press <Kbd>Edit rules</Kbd>. The liquidity and range stay; timers restart.
        </p>
        <h3>Why is the same pair listed with different fees?</h3>
        <p>Each fee tier is a separate Uniswap pool. Rules and limit orders work in pools that use Alucard’s hook; the app labels the others.</p>
      </Section>
    ),
  },

  // ================================================================ developer
  {
    id: "architecture",
    title: "Architecture",
    group: "dev",
    keywords: "architecture contracts flow diagram hook conditionalorders poolmanager",
    render: () => (
      <Section dev id="architecture" title="Architecture" lead="Who calls what, and where the money is.">
        <Architecture />
        <table>
          <thead>
            <tr>
              <th>Contract</th>
              <th>Role</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>
                <code>RuleHook</code>
              </td>
              <td>
                Hook with afterInitialize (registers the pool in a 24-bit pool table), beforeSwap (tick before, flash-loan flag) and afterSwap (fills crossed
                limit buckets). Limit orders: place, cancel, claim, fillBucket.
              </td>
            </tr>
            <tr>
              <td>
                <code>ConditionalOrders</code>
              </td>
              <td>
                Owns positions with rules. createOrder, updateOrder, execute (anyone), cancel, withdraw (held payouts), plus views for the app.
              </td>
            </tr>
            <tr>
              <td>
                <code>OrderState</code>
              </td>
              <td>Library packing a rule into one 256-bit word: two independent 128-bit halves.</td>
            </tr>
          </tbody>
        </table>
        <h3>Life of an order</h3>
        <Steps
          items={[
            <>
              <code>createOrder</code> validates both sides, stores two slots, then <code>unlock</code> → <code>modifyLiquidity(salt = orderId)</code>; the owner settles
              the tokens.
            </>,
            <>
              A keeper sees <code>canExecute(id, upper) == true</code> and calls <code>execute</code>; the contract re-checks the condition at the current tick.
            </>,
            <>
              Inside <code>unlockCallback</code>: remove → reserve keeper ceiling → swap (optional) → add (optional) → update the side → pay keeper → close or
              store.
            </>,
            <>When both sides are off or no liquidity is left, everything is removed and paid to the owner.</>,
          ]}
        />
      </Section>
    ),
  },
  {
    id: "addresses",
    title: "Addresses",
    group: "dev",
    keywords: "addresses deployment sepolia etherscan pools tokens",
    render: () => (
      <Section dev id="addresses" title="Addresses" lead="Ethereum Sepolia (chain id 11155111). Source of truth: deployments/*.json.">
        <table>
          <thead>
            <tr>
              <th>Contract</th>
              <th>Address</th>
            </tr>
          </thead>
          <tbody>
            {(
              [
                ["RuleHook", CORE.ruleHook],
                ["ConditionalOrders", CORE.conditionalOrders],
                ["TestFaucet", CORE.faucet],
                ["Uniswap PoolManager", CORE.poolManager],
                ["Uniswap PositionManager", CORE.positionManager],
                ["Swap router (hookmate)", CORE.swapRouter],
                ["Permit2", CORE.permit2],
              ] as [string, string][]
            ).map(([n, a]) => (
              <tr key={n}>
                <td>{n}</td>
                <td>
                  <A a={a} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <h3>Test tokens</h3>
        <table>
          <thead>
            <tr>
              <th>Token</th>
              <th>Decimals</th>
              <th>Address</th>
            </tr>
          </thead>
          <tbody>
            {TOKENS.filter((t) => !t.native).map((t) => (
              <tr key={t.symbol}>
                <td>t{t.symbol}</td>
                <td>{t.decimals}</td>
                <td>
                  <A a={t.address} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <h3>Pool table</h3>
        <table>
          <thead>
            <tr>
              <th>Index</th>
              <th>Pool</th>
              <th>Spacing</th>
              <th>Hook</th>
            </tr>
          </thead>
          <tbody>
            {POOLS.map((p) => (
              <tr key={p.index}>
                <td>{p.index}</td>
                <td>
                  {p.token0.symbol} / {p.token1.symbol} · {p.key.fee / 10_000}%
                </td>
                <td>{p.key.tickSpacing}</td>
                <td>{p.hooked ? "RuleHook" : "none"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>
    ),
  },
  {
    id: "storage",
    title: "Order storage",
    group: "dev",
    keywords: "storage layout bits slot packing orderstate word half edge checker value aux",
    render: () => (
      <Section dev id="storage" title="Order storage" lead="Two storage slots per order. The rule lives in one 256-bit word.">
        <h3>Slot 0: written once</h3>
        <BitMap which="slot0" />
        <h3>Slot 1: the rule, two independent 128-bit halves</h3>
        <p>
          Bits 0–127 are the lower side (fires when the tick falls), bits 128–255 the upper side (fires when it rises, or on time). Each half holds everything
          its own check needs, so checking one side never reads the other.
        </p>
        <BitMap which="half" />
        <Callout kind="note">
          In code the struct fields are <code>uint8</code>/<code>uint16</code> (Solidity has no 4-bit type); <code>encodeSide</code> packs them to the widths above
          and reverts <code>FieldTooLarge</code> rather than letting a value spill into its neighbour. A fuzz test changes one field at a time and checks
          nothing else moves.
        </Callout>
        <h3>Decode a word</h3>
        <Decoder />
      </Section>
    ),
  },
  {
    id: "encoding",
    title: "Encoding a rule",
    group: "dev",
    keywords: "encoding encoderules side lane orientation baseis0 tick price checker actions validate",
    render: () => (
      <Section dev id="encoding" title="Encoding a rule" lead="How the editor’s blocks become a contract side (lib/rules.ts).">
        <h3>Lanes and sides</h3>
        <p>
          The UI speaks in the base token’s price (“if WETH falls”). Ticks measure token1 per token0, so when the base token is token1 a falling base price is a
          rising tick. The app picks the base by a fixed ranking (USDC, USDT, DAI, WETH, ETH, WBTC, LINK: the earlier one is the quote).
        </p>
        <Code lang="ts">{`contractSide(pool, lane) = (lane === "up") === pool.baseIs0 ? "upper" : "lower"
// a "price in another pool" trigger uses the WATCHED pool's orientation
tick(price) = log(t1per0 * 10^(dec1 - dec0)) / log(1.0001),  t1per0 = baseIs0 ? price : 1 / price`}</Code>
        <h3>Blocks to fields</h3>
        <table>
          <thead>
            <tr>
              <th>Block</th>
              <th>Fields</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Leaves my range (+x%)</td>
              <td>
                <code>checker=1</code>, <code>value = ticks(x%)</code>; with repeating Follow, at least one spacing
              </td>
            </tr>
            <tr>
              <td>Price reaches P</td>
              <td>
                <code>checker=2</code>, <code>value = tick(P)</code>, <code>aux = 0</code>
              </td>
            </tr>
            <tr>
              <td>Price in pool #n reaches P</td>
              <td>
                <code>checker=2</code>, <code>value</code> = tick in pool n, <code>aux = n</code>
              </td>
            </tr>
            <tr>
              <td>Every h hours</td>
              <td>
                <code>checker=3</code>, <code>value = h × 60</code>
              </td>
            </tr>
            <tr>
              <td>Withdraw x% / Send fees</td>
              <td>
                bit 1 (remove), <code>removeBps = x × 100</code>; “send fees” clears bit 0 (otherwise set)
              </td>
            </tr>
            <tr>
              <td>Convert to T</td>
              <td>
                bit 2, <code>swapToToken1 = (T is token1)</code>
              </td>
            </tr>
            <tr>
              <td>Compound / Follow (w%)</td>
              <td>
                bit 3, <code>addMode</code> 0 / 1; Follow also sets remove 100% and <code>shape</code> = ⌈ticks(w)/spacing⌉ (upper: bits 0–10, lower: 11–21)
              </td>
            </tr>
            <tr>
              <td>Repeat</td>
              <td>
                <code>repeat</code>; a repeating price level without add stores its step in <code>shape</code>
              </td>
            </tr>
          </tbody>
        </table>
        <h3>Validation (ConditionalOrders._validateSide)</h3>
        <ul>
          <li>Actions must include remove, keep-fees or add; swap and add together are rejected.</li>
          <li>TIME needs value &gt; 0; EDGE needs value ≥ 0; a TICK pool index must exist.</li>
          <li>A repeating TICK side without add needs a step; one-sided add needs EDGE, remove 100% and a width.</li>
          <li>A repeating EDGE side must move its range (one-sided add), and its margin must be at least one spacing.</li>
        </ul>
        <p>
          <code>scripts/check-rules.ts</code> encodes every template on every pool and dry-runs <code>createOrder</code> against the live contract (56 cases), and
          checks <code>encode(decode(x)) == x</code>.
        </p>
      </Section>
    ),
  },
  {
    id: "execution",
    title: "Execution, step by step",
    group: "dev",
    keywords: "execute execution flow wouldrefire close reserve swap add",
    render: () => (
      <Section dev id="execution" title="Execution, step by step" lead="What ConditionalOrders._execute does, in order.">
        <Code lang="text">{`1  side off?                            -> revert SideOff
2  pool (or watched pool) swapped in this tx? -> revert SwappedThisTx
3  condition at the current tick / time?      -> else revert ConditionNotMet
4  refTick = trigger level (EDGE/TICK) or current tick (TIME)
5  remove removeBps of liquidity; fees collected with it
6  reserve = maxKeeperFeeBps of everything removed; fees not kept -> owner
7  swap (bit 2): all of one token, price limit = refTick -/+ maxSlippage*10,
   skipped if the price is already past the limit
8  add (bit 3): same range, or one-sided next to the price (follow)
9  side: lastRun = now; repeat ? (TICK without add: value += step) : clear
10 pay keeper out of the reserve
11 no liquidity left or both sides off -> remove the rest, pay owner, delete
12 same side would fire again at once     -> revert WouldRefire
13 pay out everything else to the owner, store the new word`}</Code>
        <p>
          Payouts take the tokens to the contract first and then try to send them (ETH with a 100,000 gas stipend). If a send fails, the amount is recorded in{" "}
          <code>owed[owner][currency]</code> and the owner calls <code>withdraw(currency, to)</code>.
        </p>
      </Section>
    ),
  },
  {
    id: "limit-internals",
    title: "Limit order internals",
    group: "dev",
    keywords: "limit internals bucket epoch fee accounting bitmap backlog dust minfill cap",
    render: () => (
      <Section dev id="limit-internals" title="Limit order internals" lead="Buckets, fair fees, and why swappers never pay for dust.">
        <h3>Epoch (one fill cycle of one bucket)</h3>
        <Code lang="solidity">{`struct Epoch {
  uint128 liquidityTotal; uint128 proceeds0;           // slot 0
  uint128 proceeds1; uint24 poolIndex; int24 tickLower;
  bool sellToken0; bool filled; bool inBitmap;         // slot 1
  uint256 feePerLiq0; uint256 feePerLiq1;              // slots 2-3, Q128
}
struct Share { uint128 liquidity; uint128 debt0; uint128 debt1; }`}</Code>
        <p>
          Fees collected when someone joins or leaves are credited to the holders at that moment through a fee-per-liquidity counter and per-user debt (like
          Uniswap’s feeGrowth), so a newcomer never takes fees earned before they joined. Each fill amount sits in a slot that already holds data, so recording
          a fill rewrites slots (~2.9k gas) instead of creating them (~20k): about 69k gas per bucket filled inside a swap.
        </p>
        <h3>Anti-dust</h3>
        <table>
          <tbody>
            <tr>
              <td>
                <code>MIN_FILL_BPS = 1</code>
              </td>
              <td>A bucket is filled inside swaps only if it holds ≥ 0.01% of the pool’s active liquidity.</td>
            </tr>
            <tr>
              <td>
                <code>MAX_FILLS_PER_SWAP = 50</code>
              </td>
              <td>At most ~3.5M gas of fills per swap; the rest wait in a per-pool backlog that the next swaps finish first.</td>
            </tr>
            <tr>
              <td>
                <code>fillBucket</code>
              </td>
              <td>Anyone fills a crossed bucket; reward = (gas + 50,000) × capped gas price × 110%, at most 1% of the proceeds (native-ETH pools).</td>
            </tr>
          </tbody>
        </table>
      </Section>
    ),
  },
  {
    id: "backtest-api",
    title: "Backtest API",
    group: "dev",
    keywords: "backtest api engine python vercel numpy request response",
    render: () => (
      <Section dev id="backtest-api" title="Backtest API" lead="A Vercel Python function in the same project as the app.">
        <Code lang="http">{`GET /api/backtest?q=<base64url(JSON)>     # cacheable: the history never changes
POST /api/backtest  (JSON body)            # same, not cached`}</Code>
        <Code lang="json">{`{
  "pool": "eth_usdc_030" | "eth_usdc_005",
  "start": 1775347200, "days": 90,            // or "mode": "windows" (every 30-day window, weekly)
  "depositUsd": 10000,
  "range": { "loPct": -5, "hiPct": 5 } | { "full": true },
  "rules": { "down": Lane, "up": Lane },     // the editor's model; price triggers as pricePct
  "keeperFeeBps": 10, "slippagePct": 1, "delaySec": 12,
  "keeperCostUsd": 0.01, "keeperMode": "gas" | "ceiling"
}`}</Code>
        <p>
          The engine (<code>frontend/api/_engine.py</code>, numpy only) ports <code>encodeRules</code> and runs the contract’s steps on each recorded swap. A
          keeper executes a set delay after a condition holds, at the price after that swap, and only if it still holds. Fees follow lp_study’s validated
          replay:
        </p>
        <Code lang="text">{`fee earned on a swap = fee_LP × overlap_fraction × L_position / (L_pool + L_position)
overlap_fraction ∈ [0, 1]: share of the swap's input that traded inside your range`}</Code>
        <p>
          Data: <code>frontend/api/_data/*.npz</code>, exported by <code>lp_study/export_backtest.py</code>. Checks:{" "}
          <code>lp_study/tests/test_rules_backtest.py</code> (23 tests: fees equal lp_sim’s replay to 1e-9, exits at the swap the contract implies, encoding
          equal to the frontend’s for both token orders).
        </p>
      </Section>
    ),
  },
  {
    id: "reference",
    title: "Function reference",
    group: "dev",
    keywords: "functions abi events reference api createorder execute placelimit",
    render: () => (
      <Section dev id="reference" title="Function reference">
        <h3>ConditionalOrders</h3>
        <table>
          <tbody>
            {(
              [
                ["createOrder(CreateParams) payable → orderId", "Add liquidity with a rule. Native ETH as msg.value; extra refunded."],
                ["updateOrder(id, UpdateParams)", "Owner only. New rule; range and liquidity unchanged; timers restart."],
                ["execute(id, upper)", "Anyone. Runs one side if its condition holds."],
                ["cancel(id)", "Owner any time; anyone after expiry. Everything to the owner."],
                ["withdraw(currency, to)", "Collect payouts that could not be sent."],
                ["canExecute(id, upper) view", "For keepers."],
                ["getOrder(id) / ordersOf(owner) / orderAmounts(id) / poolState(index)", "Views for apps."],
              ] as [string, string][]
            ).map(([f, d]) => (
              <tr key={f}>
                <td>
                  <code>{f}</code>
                </td>
                <td>{d}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <h3>RuleHook</h3>
        <table>
          <tbody>
            {(
              [
                ["placeLimit(key, tickLower, sellToken0, amount) payable → epochId", "Join or open the bucket at that price."],
                ["cancelLimit(epochId, to) / claimLimit(epochId, to)", "Before / after the fill."],
                ["fillBucket(key, tickLower, sellToken0) → reward", "Fill a crossed bucket no swap filled."],
                ["registerPool(key) → index", "Add a hookless pool to the table (for price checks and swaps)."],
                ["swappedThisTx(poolId) view", "The flash-loan flag."],
              ] as [string, string][]
            ).map(([f, d]) => (
              <tr key={f}>
                <td>
                  <code>{f}</code>
                </td>
                <td>{d}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <h3>Events</h3>
        <p>
          <code>OrderCreated · OrderExecuted · OrderUpdated · OrderClosed · PayoutHeld · Withdrawn</code> and <code>LimitPlaced · LimitCancelled · BucketFilled · LimitClaimed · FillRewarded · PoolRegistered</code>.
        </p>
      </Section>
    ),
  },
  {
    id: "local-dev",
    title: "Run it locally",
    group: "dev",
    keywords: "local development commands tests forge npm deploy",
    render: () => (
      <Section dev id="local-dev" title="Run it locally">
        <Code lang="bash">{`# contracts
forge test                                   # 60 tests

# app + backtest API
cd frontend && npm install && npm run setup:api
npm run dev:api        # terminal 1: Python API on 127.0.0.1:8787
npm run dev            # terminal 2: http://localhost:3000

# checks
npx tsx scripts/check-rules.ts               # encodings vs the live contract
DRY_RUN=1 npx tsx scripts/keeper.ts          # what the keeper would run
cd ../../Uniswap-Ext/lp_study && .venv/bin/python -m pytest tests/test_rules_backtest.py`}</Code>
        <p>
          Deploying: <code>DEPLOY.md</code>. Contract deployment scripts: <code>script/sepolia/01–05</code> (Sepolia needs{" "}
          <code>--gas-estimate-multiplier</code>; see <code>deployments/README.md</code>).
        </p>
      </Section>
    ),
  },
];
