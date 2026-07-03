# Security Model

## Private-key handling

The interactive runner (`yarn op`) never accepts a private key from command-line
arguments or files. It is collected via a hidden terminal prompt and passed to
the Foundry script through the `PRIVATE_KEY` environment variable only for the
lifetime of the subprocess. The key is never logged or persisted.

For scripted usage you can also export `PRIVATE_KEY` yourself and call a shell
wrapper directly. The wrappers leave it in the subprocess environment and do not
convert it into a `--private-key` process argument:

```bash
STAKER=0x... PRIVATE_KEY=0x... yarn op:stake-delegate 1000
```

Hardware-wallet signers (`LEDGER=1`, `TREZOR=1`) and Foundry mnemonic accounts
(`MNEMONIC_INDEX`) are also supported; the secret never leaves the device or
Foundry's signer logic.

## Memory lifecycle

- The key is typed into the interactive prompt as `*` and exported as
  `PRIVATE_KEY` only for the lifetime of the forge subprocess.
- When the subprocess exits, the environment variable is dropped.
- Close the terminal process after signing high-value operations.

Keep the secret in the narrowest scope possible and use a hardware wallet for
production operations.

## Hardware wallets

Ledger and Trezor are supported natively by Foundry (`--ledger`, `--trezor`).
The private key never leaves the device. Test on a mainnet fork first and
verify the derived address and transaction details on the device screen.

## Transaction simulation

Every operation should be simulated before broadcast:

```bash
STAKER=0x... yarn op:sim:stake-delegate 1000
```

The `op:sim:*` scripts omit `--broadcast`, so Foundry runs the script locally
without broadcasting. The interactive `yarn op` runner also offers a "Simulate" mode.

## Audit status

This is not a third-party audit. Use at your own risk, preferably with a
hardware wallet or a well-tested Safe multisig.
