# AdGuard DNS filter → wildcard format

The [AdGuard DNS filter][filter] rebuilt daily as plain **wildcard domains**,
for resolvers that cannot read adblock syntax.

```
https://raw.githubusercontent.com/sikysikov/adguard-wildcard-blocklist/main/adguard-wildcard.txt
```

> **Disclosure — this repository is vibe coded.** The conversion script, the
> workflow and this README were written by Claude (Anthropic's AI assistant) in
> a single session, directed by the repository owner. No line of it was authored
> by hand. What the two of us did do by hand is *verify* it — see
> [How this was built](#how-this-was-built) for exactly what was tested and what
> was not, so you can judge how much to trust it.

## Why this exists

The AdGuard DNS filter ships in adblock syntax:

```
||example.com^
```

That rule blocks `example.com` **and every subdomain under it**. Blockers that
expect one domain per line cannot parse it, and the usual workaround — stripping
the `||` and `^` markers — silently throws the subdomain half away:

| form | blocks `example.com` | blocks `ads.example.com` |
|---|---|---|
| `\|\|example.com^` (source) | yes | yes |
| `example.com` (common conversion) | yes | **no** |
| `*.example.com` (this list) | yes | yes |

Whether `*.example.com` also blocks the bare `example.com` is up to your
resolver, and it matters — half the rule's meaning rides on it. OPNsense blocks
both: it strips the `*.` prefix and stores the domain with a wildcard flag, then
matches the query name first and each parent label afterwards, so the apex hits
on the exact-match pass. Its test suite asserts this directly, requiring both
`wildcard.2.local` and `a.wildcard.2.local` to match. Resolvers that read `*.`
as *subdomains only* will leave the apex unblocked — check yours.

The lost coverage is not hypothetical. Trackers increasingly move to randomised
subdomains for the express purpose of slipping past exact-match filters — the
same host reappearing as `aau3pp.`, `2hmuc5.`, `bdoef1.` and so on. An
exact-match list never catches those; a wildcard list catches all of them.

Existing conversions did not cover this. [Cebeerre/dnsblocklists][cebeerre]
converts AdGuard's *services* lists and NRD feeds, not the main DNS filter, and
AdGuard's own Hostlist Compiler only emits adblock syntax — its `Compress`
transformation runs the other way (hosts → adblock).

## What you get

The file carries a hagezi-style header, so the list's age is visible without
checking the repository:

```
# Title: AdGuard DNS filter (wildcard)
# Source: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
# Syntax: Domains Wildcard
# Number of entries: 161300
# Last modified: 2026-08-02 09:52:27 UTC
```

`Last modified` is the time the **contents** last changed, not the last time the
job ran. Runs that find no change leave the file completely untouched, so the
commit history stays meaningful. To confirm the job is alive, look at the
[Actions tab](../../actions).

## What is not converted

Only plain `||domain^` rules map cleanly onto `*.domain`. Everything else is
left out rather than converted approximately, and the header states exactly how
many lines fell into each bucket — the categories sum to the source line total,
so nothing hides in a gap between them:

| category | example | why it is skipped |
|---|---|---|
| exception rules | `@@\|\|example.com^` | an allowlist entry, not a block |
| regex rules | `/^ads\d+\.example\.com$/` | no wildcard-domain equivalent |
| rules with modifiers | `\|\|example.com^$third-party` | conditional on request context |
| wildcard inside the domain | `\|\|ads-*.example.com^` | `*` only works as a leading label |
| substring rules | `.example.com^` | not anchored to a domain boundary |
| no trailing separator | `\|\|example.com` | matches more than the domain tree |

The last two rows are worth spelling out, because they fail in *opposite*
directions and neither is a safe approximation:

- `.example.com^` has no `||` anchor, so it is an ordinary substring pattern: it
  requires a literal dot before the name, which every subdomain supplies and the
  apex does not. The rule therefore covers `ads.example.com` but deliberately
  **not** `example.com`. Converting it to `*.example.com` would block the apex
  too — on OPNsense that is a real over-block the source never asked for.
- `||example.com` without the trailing `^` drops the separator requirement, so
  the match simply continues into whatever follows: it also catches
  `example.community.org` and `example.com.evil.net`, which are unrelated
  domains that merely start with the same string. `*.example.com` covers none of
  those, so the conversion would silently **under-block**.

Exceptions are deliberately **not** published as a companion allowlist. Most
consumers already maintain their own, and a second one invites confusion about
which takes precedence.

## Failure behaviour

A blocklist that quietly goes stale is worse than one that visibly breaks, so
the build refuses to publish rather than degrade:

- **HTTP status and body are checked** before anything is parsed.
- **Absolute floor** — under 100 000 entries the build fails and publishes
  nothing. This also backstops a source that returns `200` with a body that
  cannot be parsed.
- **Shrink guard** — if the list drops more than 20 % against the committed
  version, the build fails.

In every failure case the published file is left exactly as it was, and the
workflow goes red so GitHub sends the owner a notification.

## Using it

**OPNsense** (Unbound DNSBL) — *Services → Unbound DNS → Blocklist → Custom
lists*. Add the raw URL at the **end** of the list; the `customN` index is
positional, so removing an entry from the middle renumbers the rest.

Verify the wildcard actually took effect by resolving a random prefix under a
domain from the list — a random label cannot appear in any blocklist, so a
block can only come from wildcard logic:

```
drill -Q A randomprefix.somedomain-from-the-list.com @127.0.0.1
```

It must answer `0.0.0.0`.

Any other resolver that understands `*.domain` entries can consume the list the
same way. Check your resolver's documentation first — support for the `*.`
prefix is not universal, and a resolver that treats it as a literal hostname
will match nothing at all.

## Building it yourself

```sh
bash convert.sh
```

`SOURCE_URL`, `OUTPUT`, `MIN_ENTRIES` and `MAX_SHRINK_PCT` can be overridden
from the environment, which is how the safety nets are exercised against a
healthy source.

## How this was built

Written by an AI assistant, so the useful question is not who typed it but what
was actually checked. Verified by observation:

- **Each safety net was made to fire.** The input check against a 404 URL, the
  floor by raising `MIN_ENTRIES` above the real entry count, the shrink guard by
  inflating the committed list to twice its size. All three failed the build and
  left the published file untouched.
- **The published file was fetched back from the raw URL** and checked against
  its own header: declared entry count matches the real payload, every line
  carries the `*.` prefix, no CR bytes.
- **"Commit only on change" was confirmed by a second workflow run**, which
  produced no commit.
- **The apex claim above was verified against OPNsense's source**, not assumed —
  the matching code and its test suite, not the documentation.

Known gaps, stated plainly:

- The **empty-body branch has never fired in a test.** A source returning `200`
  with nothing in it would be caught by the entry floor instead, so the outcome
  is right, but that specific line is unexercised.
- Behaviour is verified **on OPNsense only.** Everything said about other
  resolvers is inference from their documentation.
- The list is a **syntax transformation and nothing more.** No judgement is
  applied to what AdGuard chooses to block, and no attempt is made to detect a
  source that has been compromised upstream — only one that has shrunk or
  disappeared.

## Licence and attribution

The conversion script and workflow are MIT licensed — see [LICENSE](LICENSE).

`adguard-wildcard.txt` is **not** original work. It is a derivative of the
[AdGuard DNS filter][filter], which is published by
[AdGuard][adguardteam] under the **GNU General Public License v3.0**, and it
stays under that licence. All credit for the filtering data belongs to the
AdGuard team and its contributors. This repository only changes the syntax.

[filter]: https://github.com/AdguardTeam/AdguardFilters
[adguardteam]: https://github.com/AdguardTeam
[cebeerre]: https://github.com/Cebeerre/dnsblocklists
