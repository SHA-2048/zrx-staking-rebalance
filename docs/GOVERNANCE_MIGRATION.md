# Governance Migration

The new 0x governance model uses a wrapped ZRX token (`wZRX`) that delegates
voting power to a chosen address. This project provides five migration paths.

## 1. Full legacy-stake migration (`wrap full`)

For ZRX that is currently staked/delegated in the legacy 0x staking system:

```bash
STAKER=0x... DELEGATEE=0x... yarn op:wrap:full
```

Or interactively:

```bash
yarn op
# choose wrap → full
```

The script performs:

1. **Undelegate all** delegated stake.
2. Require the active staking epoch to have ended, then call `endEpoch()`.
3. **Atomically** `unstake(amount)`, `approve(ZRX, wZRX, amount)`,
   `wZRX.depositFor(staker, amount)`, `wZRX.delegate(delegatee)`, and reset the
   ZRX approval.

`amount` is determined on-chain — the full delegated stake is wrapped. In
production, wait until the current staking epoch has actually ended before
broadcasting; fork tests and local simulations may warp time. Simulate first:

```bash
STAKER=0x... DELEGATEE=0x... yarn op:sim:wrap:full
```

## 2. Liquid-only wrap (`wrap liquid`)

If the ZRX is already unstaked and sitting in the wallet as ERC-20 balance:

```bash
STAKER=0x... DELEGATEE=0x... yarn op:wrap:liquid
```

This only performs:

1. `approve(ZRX, wZRX, amount)`
2. `wZRX.depositFor(staker, amount)`
3. `wZRX.delegate(delegatee)`
4. `approve(ZRX, wZRX, 0)`

`amount` is the full liquid ZRX balance. Simulate first:

```bash
STAKER=0x... DELEGATEE=0x... yarn op:sim:wrap:liquid
```

## 3. Exclude-pools wrap (`wrap exclude-pools`)

To keep some pools delegated while moving the rest to wZRX:

```bash
STAKER=0x... DELEGATEE=0x... yarn op:wrap:exclude-pools "0x31,0x48"
```

The script undelegates from every pool except the excluded ones, requires the
active staking epoch to have ended, calls `endEpoch()`, unstakes the requested
amount, then wraps and delegates it. Pools are passed as one comma-separated string. Simulate first:

```bash
STAKER=0x... DELEGATEE=0x... yarn op:sim:wrap:exclude-pools "0x31,0x48"
```

## 4. Multi-delegate wrap (`wrap multi-delegate`)

To split liquid ZRX across several delegatees, each in its own 1-of-1 child Safe:

```bash
DELEGATEES=0x...,0x...,0x... AMOUNTS=100000,100000,100000 yarn op:wrap:multi-delegate
```

The script:

1. Approves the wZRX contract to spend the total ZRX.
2. For each delegatee, deploys a child Safe (if needed) owned solely by the
   master Safe, deposits the allocated ZRX into wZRX for that child Safe,
   approves the delegate transaction hash on the child Safe, and executes the
   delegate transaction.
3. Resets the ZRX approval.

When the master Safe is the staker, the entire sequence is submitted as one
batched `execTransaction` so every inner call originates from the master Safe.

## 5. Old treasury migration

The old 0x treasury at `0x0bb1810061c2f5b2088054ee184e6c79e1591101` holds
assets that can only be moved through passed governance proposals. This step is
**not** executed by 0x Labs; it is proposed and voted on by a **voting
delegate** — an address that holds delegated voting power (staked ZRX or wZRX)
in the old 0x treasury governance system.

To migrate the assets to the new governance treasury (`ZeroExTreasuryGovernor`
at `0x4822cfc1e7699bdb9551bdfd3a838ee414bc2008`), the voting delegate first
proposes:

```bash
PROPOSER=0x... yarn op:treasury:propose "0x31,0x48"
```

This creates a ZrxTreasury proposal whose actions move:

- all **ZRX**
- all **wCELO**
- all **MATIC** (approved to the Polygon migration contract, migrated 1:1 to
  **POL**, then transferred)

After the proposal passes and reaches its execution epoch, run:

```bash
PROPOSER=0x... yarn op:treasury:execute <proposalId>
```

The voting delegate acting as proposer must have at least `proposalThreshold`
voting power in the old treasury. Pass any operated pools when proposing.
Simulate first:

```bash
PROPOSER=0x... yarn op:sim:treasury:propose "0x31,0x48"
PROPOSER=0x... yarn op:sim:treasury:execute <proposalId>
```

## Safe multisig workflow

If the staker or proposer above is a Safe multisig, every state-changing script
must be run twice:

1. `SAFE_MODE=approve` — each Safe owner runs the script once to broadcast
   `safe.approveHash(txHash)` from their own signer wallet.
2. `SAFE_MODE=execute` (default) — once enough owners have approved, anyone can
   run the script to assemble the approved-hash signatures and execute the
   batched transaction through the Safe.

For example, with a 2-of-2 Safe:

```bash
# Owner 1
SAFE_MODE=approve LEDGER=1 yarn op:treasury:propose

# Owner 2
SAFE_MODE=approve LEDGER=1 yarn op:treasury:propose

# Anyone, after both approvals are on-chain
LEDGER=1 yarn op:treasury:propose
```

The same pattern applies to staking, redelegation, wrapping, and treasury
operations. During the approve phase the script logs that the execute phase is
still pending and does not claim the operation is complete.

## Contracts

| Contract | Mainnet address |
|----------|-----------------|
| ZRX token | `0xE41d2489571d322189246DaFA5ebDe1F4699F498` |
| ZRXWrappedToken (wZRX) | `0xfcfaf7834f134f5146dbb3274bab9bed4bafa917` |
| ZeroExVotesProxy | `0x9c766e51b46cbc1fa4f8b6718ed4a60ac9d591fb` |
| Old ZRX Treasury | `0x0bb1810061c2f5b2088054ee184e6c79e1591101` |
| New governance treasury (ZeroExTreasuryGovernor) | `0x4822cfc1e7699bdb9551bdfd3a838ee414bc2008` |
| Polygon MATIC→POL migration | `0x29e7DF7b6A1B2b07b731457f499E1696c60E2C4e` |
| POL token | `0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6` |
| wCELO token | `0xe452e6ea2ddeb012e20db73bf5d3863a3ac8d77a` |
| MATIC token | `0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0` |
