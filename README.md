# zrx-staking-rebalance

A utility to reallocate 0x (ZRX) staking positions across specific staking pools
and optionally migrate ZRX to the wrapped-ZRX governance token.

Operations are implemented as native Foundry scripts in `script/*.s.sol` and can
be run through the interactive runner (`yarn op`), per-action package scripts,
or the shell wrappers directly.

## Project structure

```
script/                   # Foundry Solidity scripts
  StakeAndDelegate.s.sol
  Redelegate.s.sol
  WrapGovernance.s.sol
  WrapGovernanceMultiDelegate.s.sol
  TreasuryMigration.s.sol
sh/                       # Bash wrappers and the interactive runner
  common.sh               # Shared shell helpers
  op.sh                   # Interactive runner
  run-forge.sh            # Low-level forge script wrapper
  install-foundry-deps.sh # Update git submodules
  stake-and-delegate.sh
  delegate-equal.sh
  redelegate.sh
  wrap-governance.sh
  wrap-governance-multi-delegate.sh
  treasury.sh
src/
  interfaces/             # Minimal Solidity contract interfaces
  constants/Constants.sol # Mainnet addresses and target pool ids
  libraries/              # Shared helpers (LibStaking, LibSafe, LibSafeChild)
  types/Types.sol         # Common structs and enums
test/
  Fixtures.sol            # Common test setup helpers
  Operations.t.sol        # Foundry fork tests (direct script execution)
  SafeExecution.t.sol     # Foundry fork tests through real Safe approveHash/execTransaction
  TreasuryMigration.t.sol # Foundry fork tests for treasury proposal creation
```

`WrapGovernanceMultiDelegate` wraps ZRX into wZRX and splits it across
multiple **1-of-1 child Safe wallets** (one per delegatee). Each child Safe is
deterministically deployed from the master Safe via the official Safe v1.3.0
proxy factory, owned solely by the master Safe, and delegates its wZRX to the
intended address.

## Install

Requires [Foundry](https://book.getfoundry.sh/).

```bash
# Install / update Foundry libraries
./sh/install-foundry-deps.sh

# Compile Solidity
yarn build
# or: forge build
```

## Configuration

Copy `.env.example` to `.env` and set at least `RPC_URL`:

```bash
cp .env.example .env
# edit .env
```

| Variable | Purpose |
|----------|---------|
| `RPC_URL` | Ethereum JSON-RPC endpoint (required) |

## Key addresses

All on-chain addresses live in `src/constants/Constants.sol`.

- `OLD_ZRX_TREASURY` and `NEW_ZRX_TREASURY` are the 0x governance treasury
  **contracts** (timelock/Governor style), not Safe wallets.
- `LEGACY_STAKE_SAFE_OWNER` (`0x5775afA796818ADA27b09FaF5c90d101f04eF600`) is
  the Safe multisig that owns the delegated stake in the legacy ZRX staking
  system.
- `OX_LABS_DEPLOYMENT_SAFE` (`0x8E5DE7118a596E99B0563D3022039c11927f4827`) is
  the new 0x Labs deployment Safe (taken from 0x Settler's mainnet
  `chain_config.json`).

The actors are intentionally separate:

- **Staking reallocation** (`stake-delegate`, `redelegate`, `wrap`) is executed
  by 0x Labs from their EOA or Safe wallets.
- **Treasury migration** is proposed and executed by a **voting delegate** — an
  address that holds delegated voting power (staked ZRX or wZRX) in the old 0x
  treasury governance system, not by 0x Labs directly.

## Run an operation

### Interactive runner (recommended)

```bash
yarn op
```

This prompts for:

1. Operation (stake-delegate, delegate-equal, redelegate, wrap, treasury)
2. Staker / proposer address
3. Operation parameters (amount, pools, mode, delegatee, etc.)
4. Signer (private key, Ledger, Trezor, or mnemonic)
5. Simulate or execute

The runner prints a summary, streams the forge output to the terminal, and
never logs the private key.

### Per-action scripts

Each operation has two package scripts:

- `op:<name>` — execute (broadcast, adds Foundry's `--broadcast` flag)
- `op:sim:<name>` — simulate (no `--broadcast`, Foundry runs locally)

Foundry scripts simulate by default and only broadcast when `--broadcast` is
passed, so `op:sim:*` is the same script without that flag.

The Solidity scripts default the staker, delegatee, and target pools from
`src/constants/Constants.sol` (`DEFAULT_STAKER`, `DEFAULT_DELEGATEE`,
`LibStaking.defaultTargetPools()`). The shell wrappers and interactive runner
let you override these via environment variables, so day-to-day usage rarely
needs to pass them explicitly.

Zero-argument examples:

```bash
yarn op:sim:stake-delegate      # stake and delegate the full ZRX balance
yarn op:sim:delegate-equal      # delegate the full undelegated balance
yarn op:sim:undelegate          # undelegate all active stake
yarn op:sim:redelegate          # undelegate all and redelegate to target pools
yarn op:sim:rebalance           # rebalance target pools to current total
yarn op:sim:wrap:liquid         # wrap all liquid ZRX
yarn op:sim:wrap:full           # wrap all active delegated stake
yarn op:sim:wrap:exclude-pools       # wrap all stake outside the target pools
yarn op:sim:wrap:multi-delegate      # split liquid ZRX across child Safe delegates
yarn op:sim:unstake                  # unstake all undelegated ZRX
yarn op:sim:treasury:propose         # propose treasury migration
```

Optional positional arguments:

```bash
# Stake 1,000,000 ZRX and delegate equally across the 3 target pools
yarn op:stake-delegate 1000000

# Delegate 1,000,000 ZRX of existing undelegated stake equally across target pools
yarn op:delegate-equal 1000000

# Rebalance so the target pools total exactly 2,000,000 ZRX
yarn op:rebalance 2000000

# Split 300k ZRX across three child Safe delegates
DELEGATEES=0x...,0x...,0x... AMOUNTS=100000,100000,100000 yarn op:wrap:multi-delegate

# Execute the treasury proposal after it has passed
yarn op:treasury:execute <proposalId>
```

Default target pools are `0x31`, `0x48`, `0x34`. To change them, edit
`src/constants/Constants.sol` and `src/libraries/LibStaking.defaultTargetPools()`.

### Direct shell usage

```bash
# Broadcast (requires a signer)
PRIVATE_KEY=0x... ./sh/stake-and-delegate.sh --broadcast 1000000
LEDGER=1 ./sh/redelegate.sh --broadcast redelegate-all
LEDGER=1 ./sh/wrap-governance.sh --broadcast full

# Simulate (no signer required beyond the --from address)
./sh/redelegate.sh redelegate-all
./sh/wrap-governance.sh liquid
DELEGATEES=0x...,0x... AMOUNTS=100000,200000 ./sh/wrap-governance-multi-delegate.sh
```

## Hardware wallets

Foundry supports hardware wallets natively:

```bash
LEDGER=1 yarn op:redelegate
TREZOR=1 yarn op:wrap:liquid
```

Always simulate first with `yarn op:sim:*` (no `--broadcast`).

## Safe multisig operations

When the staker/proposer is a Safe, the scripts cannot sign "as" the Safe
contract. Instead, `LibSafe` drives the real Safe through the canonical
`MultiSendCallOnly` contract using the approved-hash flow.

For a Safe with threshold `N`, each operation that changes on-chain state must
be run in two phases:

1. **Approve phase** — each Safe owner runs the script once with
   `SAFE_MODE=approve`. This broadcasts `safe.approveHash(txHash)` from the
   owner's own signer wallet. No state change occurs yet.

   ```bash
   SAFE_MODE=approve LEDGER=1 yarn op:stake-delegate 1000000
   ```

2. **Execute phase** — once at least `N` owners have approved on-chain, anyone
   can run the script again (default `SAFE_MODE=execute`) to assemble the
   approved-hash signatures and broadcast `safe.execTransaction(...)`, which
   delegatecalls `MultiSendCallOnly` to execute the batched calls.

   ```bash
   LEDGER=1 yarn op:stake-delegate 1000000
   ```

The same two-phase flow applies to `redelegate`, `wrap`, `treasury`, and any
other operation where the caller is a Safe. Dry-run simulations (`op:sim:*`, no
`--broadcast`) auto-approve the Safe hash on the local fork so the full Safe
execution can be inspected before any owner broadcasts an approval. Broadcast
and resume runs still require real on-chain Safe owner approvals. If the operation
only reaches the approve phase, the script logs that the execute phase is still
pending and does not emit a misleading "created"/"executed" message.

## Tests

```bash
yarn build              # Compile Foundry scripts
yarn lint               # Run forge lint
yarn test:foundry       # Foundry fork tests (requires RPC_URL)
```

Fork tests are pinned to the mainnet block defined by `Constants.FORK_BLOCK_NUMBER`
so each run is reproducible. Foundry caches forked RPC state in
`~/.foundry/cache/rpc`; in CI this directory is cached so the pinned block is only
fetched once per PR. Tests fail explicitly when `RPC_URL` is not set.

Tests call the script `run()` functions directly and mock chain state (balances,
storage slots, time) on the fork, so the same execution code is exercised without
needing a separate plan-generation path.

## Security

See [`docs/SECURITY.md`](docs/SECURITY.md).

- Private keys are prompted (hidden) by the interactive runner or supplied via
  `PRIVATE_KEY` only for the subprocess lifetime.
- Prefer hardware wallets for production operations.
- Simulate every operation before broadcasting.

## Repository access

Only authorized maintainers may create branches or merge to `main`. See
[`BRANCH_PROTECTION.md`](BRANCH_PROTECTION.md) for the required GitHub settings.

## License

Undecided. This repository is currently private and will be made public later.
See `LICENSE` for the placeholder status.
