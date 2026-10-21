# macaudit

A single shell script that reads the state of a Mac and writes one self-contained HTML report: installed applications, where they live, how much space they take, what runs at startup, which processes are loaded, how security is configured, and what changed since the last run.

No dependencies, no build step, no network access. It calls only tools that ship with macOS.

## What it reports

- **Summary**: SIP, FileVault, Gatekeeper, firewall, disk usage and Full Disk Access, with anything that needs attention listed first.
- **Changes**: what appeared, disappeared or changed since the previous run (`--diff`).
- **Machine**: model, CPU, memory, load, Secure Boot, disk.
- **Security**: the four settings above in full, plus stealth mode, XProtect version, third-party kexts, system extensions and the latest Time Machine backup.
- **Applications**: size, version, who signed the bundle, days since it was last opened and full path, sortable and filterable.
- **Packages**: Homebrew formulae and casks, and apps with an App Store receipt.
- **Startup items**: launch agents and daemons in all three directories, what each one runs, and login items.
- **Processes**: the top ones by CPU and by memory.
- **Network**: which processes listen on which ports.

Every section names the command its data came from, so any line can be checked by hand.

## What it does not do

- It changes nothing: no `defaults write`, no `launchctl unload`, no deleting, no "optimising".
- It does not ask for `sudo`. Everything that matters is readable as a normal user, but `lsof` then shows only your own processes, and `kmutil` may come back empty.
- It does not use the network. Nothing is uploaded, and the report has no external resources, so it opens offline.

It writes two things: the report, and a small snapshot under `~/Library/Application Support/macaudit`, so that the next run can tell you what changed. `--no-snapshot` turns the snapshot off.

## Install

It is one file:

```sh
curl -fsSLO https://raw.githubusercontent.com/akarazhev/macaudit/main/macaudit.sh
chmod +x macaudit.sh
./macaudit.sh
```

Read it before you run it. It is about 600 lines, and you can check in a few minutes that it sends nothing anywhere.

## Usage

```sh
./macaudit.sh                    # full report, 2-4 minutes, opens when done
./macaudit.sh --fast             # skip app sizes and signature checks, about 15 seconds
./macaudit.sh --diff             # add a section with what changed since the last run
./macaudit.sh --redact           # strip hostname, user name and home paths
./macaudit.sh -o ~/report.html --no-open
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

Each run saves a small TSV snapshot, and the last 30 are kept. `--diff` adds a list of changes right after the summary:

```
+  Application     Zed             1.85.0 · /Applications/Zed.app
−  Startup item    com.acme.agent  /Library/LaunchAgents
Δ  Signature       Handbrake       Developer ID: Old Ltd → Developer ID: New Ltd
Δ  Security        FileVault       Off → On
```

It compares applications, startup items, listening ports, Homebrew packages, security settings and the macOS version. Processes, uptime and load are left out on purpose: they change every second and would hide the useful lines. For the same reason, ports above 49152 are skipped, app size changes under 20 MB are ignored, and disk usage is reported only when it moves by three points or more.

The first `--diff` run has nothing to compare against. It says so and saves the baseline.

### Before sharing a report

The report contains your hostname, your user name, every path under your home directory, your installed software and your open ports. `--redact` replaces the identifying strings with placeholders, and the footer of every report says which mode produced it.

Snapshots under `~/Library/Application Support/macaudit` are never redacted, because they need real paths to compare against. Don't share them.

### Full Disk Access

Without it, parts of the report are incomplete. The report checks this instead of assuming it and shows the result in the summary. To grant it: System Settings › Privacy & Security › Full Disk Access, add your terminal, then restart the terminal.

## Compatibility

macOS on Apple Silicon and Intel. It is written for the `bash` 3.2 that ships with macOS, so it runs on any Mac without a newer shell. Every external call runs with `PATH` set to `/usr/bin:/bin:/usr/sbin:/sbin`, so nothing from `/usr/local/bin` or `/opt/homebrew/bin` can replace the tools the report relies on. The one exception is `brew`, which is run by absolute path and only if it exists.

A command that fails or is missing leaves a dash in the report instead of stopping the run.

## Reporting problems

Include your macOS version, whether the Mac is Apple Silicon or Intel, and the terminal output. Don't attach the report itself unless you made it with `--redact`.

## License

MIT. See [LICENSE](LICENSE).
