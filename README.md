# SessionRouter PoCs — MOR Bug Bounty Program v2

Foundry fork PoCs for two findings in the **SessionRouter** facet of the Morpheus
inference marketplace, reached through the **LumerinDiamond** on **Base**.

- Diamond: `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`
- SessionRouter facet: `0x3a3952F0e57B343F00B31f7da039Ef16389B7260`
- MOR (Base): `0x7431aDa8a591C955a994a21710752EF9b882b8e3`
- Fork block: **58057831** (Base mainnet, pinned in the test via `vm.createSelectFork`)

## Run

```bash
forge test
```

One command. Requires network access to a Base RPC (the `base` endpoint is
configured in `foundry.toml`). Compilation is intentionally light: solc 0.8.24,
optimizer 200 runs, **no via-IR**, and only minimal interfaces for the diamond
functions the tests call — the Morpheus repo itself is not compiled.

## What each test proves

### `testF1_ApprovalNotBoundToUser` — provider approval is not bound to its user

The provider signs an approval naming the **victim** (`abi.encode(bidId, chainId,
USER, timestamp)`, the production format). An unprivileged **attacker** submits
that same approval with the attacker's own 10,000 MOR stake:

- the session opens **for the attacker** (`SessionRouter._extractProviderApproval`
  decodes the user field and discards it; `openSession` never checks it),
- the attacker receives the full stipend-backed session duration
  (29.2156 MOR of stipend at the pinned block),
- the approval is marked used, and the **victim's** own `openSession` with their
  own approval reverts with `SessionDuplicateApproval`,
- control: with a fresh approval the victim opens normally — the only reason the
  first attempt failed is the burned approval.

### `testF2_ClaimForProviderSameDayFreeze` — same-day provider claim underflows

A provider with a 1 MOR stake (so the 365-day reward limiter caps the close-time
payment) runs a ~3.6 MOR session that the user closes 30 minutes **late** with a
**valid** receipt (no dispute):

- close pays exactly 1 MOR (the limiter cap); **2.599 MOR** remainder stays owed,
- the provider tops up stake so 3 MOR of limiter headroom exists,
- a same-day `claimForProvider` **reverts with an arithmetic underflow panic**:
  it subtracts a 5.399 MOR "on-hold" amount — the dispute formula applied
  unconditionally and computed over the full open→close window (`closedAt` is
  never capped at `endsAt`) — from the 2.599 MOR remainder,
- after the next UTC midnight the identical claim succeeds and pays exactly
  2.599 MOR. The remainder was frozen for the rest of the UTC day.

### `testF2_Control_FullyPaidProviderSameDayClaimAlsoPanics` — control

A provider whose limiter never binds is paid in full at close, yet a same-day
`claimForProvider` still panics (`0 − onHold`), proving the deduction is applied
unconditionally rather than only to disputed closes. Next day the same call is
a clean no-op paying 0.

## Notes

- All actors are fresh EOAs created inside the tests. Setup uses only the
  diamond's permissionless self-service flows (`providerRegister`,
  `modelRegister`, `postModelBid`) — the same flows any real user/provider runs.
  No owner/admin/multisig account is used, and no account is impersonated:
  `prank` is used only for the tests' own keypairs.
- Test accounts are funded by a fork-local storage write to the MOR balance
  mapping (the slot is discovered empirically in `setUp` and verified by a
  `balanceOf` read-back), because this Foundry build does not implement the
  ERC20 `deal` cheatcode.
- `setUp` re-verifies that the `openSession` / `claimForProvider` selectors
  still route to the SessionRouter facet address above; the tests fail loudly
  if the diamond was re-cut.
- If the pinned block's state is ever unavailable on the public RPC, bump
  `FORK_BLOCK` in `test/SessionRouterPoC.t.sol` to a fresher block; all
  assertions are derived from live fork reads, not hard-coded state.
