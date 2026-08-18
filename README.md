# macaudit

A single shell script that reads the state of a Mac and writes one self-contained HTML report: installed applications, where they live, what they take up, what runs at startup, which processes are loaded, how security is configured, and what changed since last time.

No dependencies, no build step, no network access. It calls only tools that ship with macOS.

## What it reports

- **Summary** — SIP, FileVault, Gatekeeper, firewall, disk usage, Full Disk Access, with anything that needs attention listed up front
- **Changes** — what appeared, disappeared or changed since the previous run (`--diff`)
- **Machine** — model, CPU, memory, load, Secure Boot, disk
- **Security** — the four toggles above in full, plus stealth mode, XProtect version, third-party kexts, system extensions, latest Time Machine backup
- **Applications** — sortable and filterable: size, version, who signed the bundle, how many days since it was last opened, full path
- **Packages** — Homebrew formulae and casks, apps with an App Store receipt
- **Startup items** — launch agents and daemons in all three directories, what each one actually runs, plus login items
- **Processes** — top by CPU and by memory
- **Network** — which processes are listening on which ports

Every section is labelled with the command its data came from, so any line in the report can be checked by hand.

## What it does not do

- It does not change anything. No `defaults write`, no `launchctl unload`, no deleting, no "optimising".
- It does not ask for `sudo`. Everything that matters is readable as a normal user. The trade-off is that `lsof` shows only your own processes and `kmutil` may come back empty.
- It does not touch the network. Nothing is uploaded, and the report has no external resources — it renders offline, forever.

It writes exactly two things: the report you asked for, and a small snapshot under `~/Library/Application Support/macaudit` so that later runs can tell you what changed. `--no-snapshot` turns the second one off.

## Install

Via Homebrew:

```sh
brew install akarazhev/tap/macaudit
```

Or just take the file — it is one script and it has no install step:

```sh
curl -fsSLO https://github.com/akarazhev/macaudit/releases/latest/download/macaudit-1.3.tar.gz
shasum -a 256 macaudit-1.3.tar.gz     # compare against the checksum in the release notes
tar xzf macaudit-1.3.tar.gz
./macaudit-1.3/macaudit.sh
```

Read it before you run it. It is 470 lines, and for a tool that inventories your whole system that is the point — you can confirm in five minutes that it sends nothing anywhere.

## Usage

```sh
macaudit                    # full report, 2-4 minutes, opens when done
macaudit --fast             # skip app sizes and signature checks, ~15 seconds
macaudit --diff             # add a section listing what changed since the last run
macaudit --redact           # strip hostname, user name and home paths
macaudit -o ~/report.html --no-open
```

| Option | Effect |
| --- | --- |
| `-o, --out FILE` | where to write the report (default `~/Desktop/mac-audit-<date>.html`) |
| `--fast` | skip `du` and `codesign`; sizes and signers are left blank |
| `--system-apps` | include `/System/Applications` |
| `--diff` | compare against the most recent snapshot |
| `--diff-with FILE` | compare against a specific snapshot |
| `--no-snapshot` | do not save a snapshot on this run |
| `--redact` | replace identifying strings before writing the file |
| `--no-open` | do not open the report when it is done |
| `-V, --version` | print the version |

### Comparing runs

Each run saves a compact TSV snapshot; the last 30 are kept. `--diff` adds a ledger of changes right after the summary:

```
+  Application     Zed             1.85.0 · /Applications/Zed.app
−  Startup item    com.acme.agent  /Library/LaunchAgents
Δ  Signature       Handbrake       Developer ID: Old Ltd → Developer ID: New Ltd
Δ  Security        FileVault       Off → On
```

Applications, startup items, listening ports, Homebrew packages, security toggles and the macOS version are compared. Processes, uptime and load deliberately are not — they change every second and would bury the useful lines. For the same reason ephemeral ports above 49152 are skipped, app size changes under 20 MB are ignored, and disk usage is reported only when it moves by three points or more.

The first `--diff` run has nothing to compare against and says so, then saves the baseline.

### Before sharing a report

The report contains your hostname, your user name, every path under your home directory, your installed software and your open ports. That is a decent profile of you. `--redact` replaces the identifying strings with placeholders, and the footer of every report states which mode produced it.

Snapshots under `~/Library/Application Support/macaudit` are never redacted — they need real paths to diff against. Don't share those.

### Full Disk Access

Without it, parts of the report are quietly incomplete. The report measures this rather than assuming it and shows the result in the summary. To grant it: System Settings › Privacy & Security › Full Disk Access, add your terminal, restart the terminal.

## Verifying what you downloaded

Release tarballs are built by GitHub Actions from the tagged commit, with a reproducible `tar` invocation — fixed sort order, zeroed ownership and timestamps. Rebuilding the same tag on your own machine produces a byte-identical archive, so the published checksum can be reproduced rather than merely trusted:

```sh
git checkout v1.3
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 1980-01-01' \
    -czf - macaudit.sh README.md LICENSE | shasum -a 256
```

## Compatibility

macOS on Apple Silicon and Intel. Written for the `bash` 3.2 that ships with macOS, so it runs as-is on any Mac without installing a newer shell. Every external call is made with `PATH` pinned to `/usr/bin:/bin:/usr/sbin:/sbin` — nothing from `/usr/local/bin` or `/opt/homebrew/bin` can shadow the tools the report relies on. The one exception is `brew` itself, which is run by absolute path and only if it exists.

Any command that fails or is unavailable leaves a dash in the report rather than aborting the run.

## Reporting problems

Include your macOS version, whether the Mac is Apple Silicon or Intel, and the terminal output — not the report file, unless you generated it with `--redact`.

## License

MIT. See [LICENSE](LICENSE).
