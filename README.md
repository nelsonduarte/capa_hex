# capa_hex

Pure-Capa hexadecimal (base16): encode and decode, lowercase and
uppercase. Zero capabilities: every function is a `(List<Int>) -> String`,
`(String) -> String`, or `(String) -> Result<List<Int>, HexError>` over
bytes and text. Nothing here can touch the filesystem, the network, the
clock, randomness, or anything else; the library holds no authority and
reads no global state. `capa --manifest` proves it (see
[Audit claim](#audit-claim)). Output is byte-identical on the Python and
Wasm backends.

Encoding is the textbook byte-to-two-nibbles transform; decoding is
**strict**, verified against Python's `binascii.hexlify` /
`bytes.fromhex` (the oracle) over known vectors, all 256 byte values,
and rejection cases.

## Status

v0.2 (seed library). **Requires capa >= 1.18.1.** The library's API is
unchanged since v0.1; the floor moved because v0.1.0's declared
`>=1.1.0` turned out to be false. capa 1.1.0 cannot compile
`example.capa` or the suite at all: they self-import `capa_hex.hex`,
and in a released tarball the project root is named `capa_hex-<tag>`,
which that compiler cannot resolve. See
[`SECURITY.md`](./SECURITY.md#the-release-guards) for how that was
found. Scope, fixed by design:

- **Lowercase hex** (`0-9a-f`), two characters per byte, high nibble
  first. `encode`.
- **Uppercase hex** (`0-9A-F`). `encode_upper`.
- **UTF-8 convenience**: `encode_utf8` encodes a String's UTF-8 bytes.
- **Strict, total decode**: rejects any non-hex character and any
  odd-length input with a typed `HexError`, never a panic and never
  wrong bytes. Accepts both lowercase and uppercase input.

Out of scope, by design:

- **Whitespace / separator-tolerant decode.** Decode is strict: it
  rejects any character outside `0-9a-fA-F` (including spaces, colons,
  and newlines) rather than silently skipping it. Strip separators
  yourself if your input has them.
- **`0x` prefixes.** Not stripped; a leading `0x` is a non-hex `x` and
  is rejected.
- **Base32 / Base64.** See `capa_base64` for Base64.

## Quick start

```capa
import capa_hex.hex

fun main(stdio: Stdio)
    // Encode a String (its UTF-8 bytes) to lowercase hex.
    stdio.println(encode_utf8("foobar"))        // -> 666f6f626172

    // Encode raw bytes (each 0..255).
    let bytes: List<Int> = [0x00, 0xFF]
    stdio.println(encode(bytes))                // -> 00ff
    stdio.println(encode_upper(bytes))          // -> 00FF

    // Decode returns a Result: malformed input is an Err, not a panic.
    // Both cases are accepted.
    match decode("00FF")
        Ok(back) -> stdio.println("${back.length()} bytes")   // 2 bytes
        Err(e)   -> stdio.println(hex_error_message(e))
```

The full runnable example is [`example.capa`](./example.capa); it
encodes a String as lowercase and uppercase hex and round-trips a
decode.

```bash
capa --run example.capa
capa --wasm --run example.capa   # byte-identical output
```

## Install via capa.toml

```toml
[dependencies.capa_hex]
git = "https://github.com/nelsonduarte/capa_hex"
tag = "v0.2.0"
verify_key = "6C1D222D491FB88031E041A536CFB426101AA24B"
```

`capa install` runs `git verify-tag` against your GPG keyring; import
the publisher's key first (see [`SECURITY.md`](SECURITY.md) for the
fingerprint provenance and `gpg --import` instructions).

## API surface

From `capa_hex.hex`:

```capa
pub fun encode(data: List<Int>)       -> String                       // lowercase 0-9a-f
pub fun encode_upper(data: List<Int>) -> String                       // uppercase 0-9A-F
pub fun decode(text: String)          -> Result<List<Int>, HexError>  // strict; both cases
pub fun encode_utf8(text: String)     -> String                       // UTF-8 bytes then encode

pub type HexError =
    InvalidCharacter(String)   // a char outside 0-9a-fA-F
    OddLength(Int)             // an input whose length is not even

pub fun hex_error_message(e: HexError) -> String
```

Bytes are `List<Int>`, each element in `0..255`. `encode_utf8` takes a
`String` and encodes its UTF-8 bytes via the language's
`String.bytes()`. The raw `encode` / `encode_upper` / `decode` forms
exist so a caller can encode non-text bytes and recover them without a
String detour.

> **Byte contract (read this if you pass `List<Int>` directly to an
> encoder).** Every element of a byte input **must be in `0..255`**. A
> value outside that range is **silently masked to its low 8 bits**
> (`x & 0xFF`), so `256` becomes `0` and `-1` becomes `255`; the
> function does **not** reject or report it. The behaviour is identical
> on both backends. The safe path is to derive bytes from a `String`
> via `encode_utf8` or `String.bytes()` (always in range), or from a
> source you have already constrained to `0..255`. The decoder always
> returns bytes in `0..255`.

### Strict decode

`decode` rejects malformed input with a typed `HexError` rather than
panicking or returning partial / wrong bytes:

- **`InvalidCharacter`**: a character outside `0-9a-fA-F` (this includes
  whitespace, separators like `:`, and any multi-byte code point).
- **`OddLength`**: an input whose length is not even, since a whole
  number of bytes needs an even number of hex digits.

`decode` checks length parity **before** scanning characters, so which
variant a rejection reports depends on the total length: an odd-length
input that also contains a non-hex character (for example `"66 6f"`,
length 5) is reported as `OddLength`, not `InvalidCharacter`. Either
way the input is rejected; the two variants are not a valid/invalid
split.

Both lowercase and uppercase input (and a mix) are accepted;
`decode(encode(x)) == x` and `decode(encode_upper(x)) == x`.

## Implementation notes

Encoding walks the input one byte at a time, emitting the high nibble
then the low nibble as digits of the selected alphabet. Decoding is the
inverse: after checking the length is even, it maps each pair of
characters to their 4-bit values (a linear scan over the fixed 16
symbols, accepting either case, rejecting non-members), then combines
them into a byte.

Capa's `Int` is a signed 64-bit integer with **checked** overflow, but
every shift here is small: a nibble shifts left by at most 4, well below
the `i64` ceiling. Each encoded byte is masked with `& 0xFF`. Bitwise
operators bind looser than `+` in Capa, so shifted terms are
parenthesised. The lowercase and uppercase forms share one encoder,
differing only in the digit String.

## Verification

The algorithm was written **oracle-first**: the expected values in the
suite come from Python's `binascii.hexlify` / `bytes.fromhex`, computed
over a corpus (known vectors, all 256 byte values, binary data, and a
UTF-8 String), then baked into the Capa tests. The scratch generator is
**not** part of the library; only `.capa` modules ship. The suite
re-asserts those vectors on both backends:

- **Known vectors:** `""`, `"f"` (`0x66` -> `"66"`), `"foobar"` ->
  `"666f6f626172"`, `0x00` -> `"00"`, `0xFF` -> `"ff"`, encode and
  decode.
- **Oracle corpus:** all 256 byte values, lowercase and uppercase,
  byte-exact against `hexlify`; a binary vector and a longer fixed
  vector; and a UTF-8 String.
- **Round-trips:** `decode(encode(x)) == x` across the corpus, plus
  every single byte value on its own.
- **Case:** uppercase input decodes equal to lowercase (and a mixed-case
  input is accepted).
- **Rejection:** odd length and non-hex characters (`g`, a space, a
  multi-byte code point) each return the expected `HexError` variant,
  never a panic or wrong bytes.

```bash
capa test          # Python backend
capa test --both   # Python + Wasm, byte-identical stdout required
```

Current output of `capa test --both`:

```
capa test: 1 file(s) under .../capa_hex/tests [backend: python+wasm]
test_hex.capa ... ok
1 test(s): 1 passed, 0 failed
```

`capa_test` is declared under `[dev-dependencies]` with the same
git + tag + verify_key shape as any published dependency, pinned to its
`v0.1.0` tag and verified against the publisher key, so `capa install`
runs the full three-layer check (lockfile SHA + GPG tag signature +
SLSA L2 provenance) on it. Dev-dependencies are resolved only when this
repository is the install root, so a consumer of `capa_hex` never
fetches the test library.

## Audit claim

Hex sits on the boundary between untrusted text and bytes, exactly where
a supply-chain attacker would want a foothold, so this library proves
the empty claim about itself. `capa --manifest` over the module reports,
for every function in `hex`:

```
declared_capabilities:                []
transitively_reachable_capabilities:  []
has_unsafe:                           false
user_defined_capabilities:            []
```

0 functions with capabilities, 0 crossing `unsafe`. Every function
additionally lists every capability (`Clock`, `Db`, `Env`, `Fs`,
`Net`, `Proc`, `Random`, `Stdio`, `Unsafe`) under
`provably_excluded_capabilities`. The only capabilities anywhere in
this repository are in the example and are the example's own (`Stdio`
to print). A program using `capa_hex` declares only the authority its
own code needs.

Since v0.2 that claim is also **enforced at release time**, not merely
reported. `capa.toml` declares

```toml
[capabilities]
max = ["Stdio"]
```

and the release runs `capa --check-capabilities` over both entry
points in a clean room. Adding, say, a `pub fun encode_file(fs: Fs,
path: String)` to `hex.capa` type-checks and compiles perfectly
happily, so `capa --check` would pass it and the release would ship a
codec that reads your filesystem. The ceiling is the step that refuses
it, by name:

```
capa: --check-capabilities: FAILED - 1 ceiling violation(s):
  - package 'capa_hex' declares max=['Stdio'] but its own code introduces 'Fs'
```

The bound is `["Stdio"]` rather than `[]` because the ceiling covers
the whole package and `example.capa` legitimately prints. So it
catches the library acquiring any of `Fs`, `Net`, `Env`, `Db`, `Proc`,
`Random`, `Clock`, `Serve` or `Unsafe`, and does **not** catch
`hex.capa` acquiring `Stdio`; `capa --manifest hex.capa` above remains
the tighter statement.

## Verifying a downloaded release

These are the commands the release's own clean-room guard runs against
the published tarball, with a released compiler, in a directory with no
siblings. They are the commands to run after extracting it:

```bash
gpg --import publisher.asc     # the dev-dependency's tag is signature-checked
capa install
capa --check hex.capa
capa --check example.capa
capa --check-capabilities hex.capa
capa --check-capabilities example.capa
capa test
```

If any of them fails on a released tarball, that is a bug in the
release and worth reporting. See
[`SECURITY.md`](./SECURITY.md#build-provenance-and-what-gates-a-release)
for the signature and attestation checks that come first.

## Honest posture

- **Verified, not audited.** The output is checked against known vectors
  and against Python's `binascii` over the corpus above, on both
  backends. It has **not** been fuzzed or independently reviewed.
- **Strict by default.** Decode rejects anything outside `0-9a-fA-F`,
  including whitespace, separators, and newlines. If your input has
  them, strip them first; this codec will not do it for you.
- **Hex is an encoding, not encryption.** It provides no confidentiality
  or integrity. Do not treat a hex string as a secret or as
  authenticated.

## License

MIT. See [`LICENSE`](./LICENSE). Release tags are GPG-signed; see
[`SECURITY.md`](./SECURITY.md) for the fingerprint and verification
instructions.
