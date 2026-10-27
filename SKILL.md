---
name: audion-build-backup
description: Keep a verified local MAIN VPS recovery set and an auto-discovered Forgejo library in MIR mode, replacing managed copies while protecting connection settings, keys and recovery snapshots; manage tunnel access and private Build-stack backups. Backups only - it never publishes, never builds, and never touches a release.
---

# Audion Sync Tools

Commands, checks and configuration. Why it is built this way is in `MEMORY.md`;
the rules of engagement are in `CLAUDE.md`; the human account is in
`Docs/USER_GUIDE_RU.md`.

Two folders, always: **the program** (this one — window, scripts, its own
`rclone`, templates, the tunnel client) and **the data** (the
neighbouring `Audion Backup <Machine>` — connection configs, R2 and cloud credentials,
snapshots, the repository library, keys and tokens; the owner-managed OpenVPN Portable is
an explicit exception and lives in data with its profiles and RDP file).
The data path is derived from where the program stands; every
wrapper and the window accept `-Root`. Never hard-code a drive letter: the same
pair lives on `E:` on the laptop and on `S:` on the workstation.

## Commands

Every action has a wrapper, and the window's buttons call exactly these. Nothing
happens in the window that cannot happen from a console.

### Backups and keys — `Runs`

    sync-backup.cmd                 verified recovery from R2 plus all Forgejo repositories
    sync-backup.cmd -WhatIf         show the plan, write nothing
    sync-backup.cmd -Only "A,B"     install only these folders; still verify the full input set
    sync-backup.cmd -Snapshot <tar> reuse a local recovery archive + adjacent .sha256; verify live Git
    import-keys.cmd                 lay keys into profile, config\rclone, git configs
    import-keys.cmd -Check          say what would change, change nothing
    import-keys.cmd -Source Store   take the Tunnel folder (golden copy), not Export Keys
    export-keys.cmd                 collect this machine's keys into Tunnel\Export
    backup.cmd                      private Build-stack archives into the R2 bucket
    backup.cmd -Publish             the same, and rotate older snapshots

`-NoPause` skips the final keyboard pause in backup/key/cloud and setup/check
wrappers, including those under `Tunnel`. Required input (passwords, host-key
confirmation, configuration choices) stays interactive.
PRIVATE BACKUP verifies file paths and sizes before rotation. An older snapshot
is retained if it contains any project/archive kind absent from the new one;
the same coverage check protects a more complete snapshot of today's date.
`-ProjectName "A,B"` selects both projects and skips rotation; `-Keep` must be
at least 1. An empty selection or failed listing stops before upload.

### Network and machines — `Tunnel\RemoteDesktop`

    check-routes.cmd                full diagnostic, report into logs\routes-*.log
    check-routes.cmd -Speed         the same plus throughput per living route
    check-router.cmd                talk to the router: model, firmware, peers
    check-router.cmd -Remember      store the router password for later runs
    check-router.cmd -Schema        print how the router describes its tunnels
    new-router-peer.cmd -WhatIf     show the commands that would issue a config
    new-router-peer.cmd -Name X     issue a WireGuard config for machine X
    new-router-peer.cmd -Name X -Remove   drop that peer from the router
    install-wireguard.cmd           install WireGuard itself, nothing else
    setup-base-vpn.cmd -From <conf> raise the tunnel straight to the router
    setup-base-vpn.cmd -Check       is it up, is there a handshake, is home visible
    setup-base-vpn.cmd -Remove      take the tunnel down, keep the config
    setup-base-vpn.cmd -Name laptop -From <conf>   raise any other tunnel
    setup-ssh-server.cmd            enable sshd on this machine (needs admin)
    restore-machine.cmd            restore selected DATA after Windows reinstall, then test SSH/SFTP
    restore-machine.cmd -Check      inspect restore inputs without writes or network requests
    restore-machine.cmd -RestoreConfig   also replace SSH profile routes from DATA (one previous copy kept)
    reverse-ssh-second-vps.cmd      REVERSE SSH TUN through SECOND VPS, MAIN VPS as fallback
    reverse-ssh-main-vps.cmd        REVERSE SSH TUN through MAIN VPS only
    reverse-ssh-check.cmd           key, port on MAIN VPS or SECOND VPS, process, is the port listening
    reverse-ssh-remove.cmd          stop the channel, delete the tunnel key from MAIN VPS or SECOND VPS
    reverse-ssh-toggle.cmd          toggle the persistent reverse SSH channel

### Terminal and file sessions — `Tunnel\RemoteDesktop`

    connect-base.cmd                interactive SSH to BASE using its configured route
    connect-base-lan.cmd            interactive SSH to BASE using its LAN address
    connect-laptop.cmd              interactive SSH to LAPTOP using its configured route
    connect-laptop-lan.cmd          interactive SSH to LAPTOP using its LAN address
    files-base.cmd                  open BASE in the configured SFTP client
    files-home.cmd                  open HOME in the configured SFTP client
    files-laptop.cmd                open LAPTOP in the configured SFTP client
    files-router.cmd                open the router in the configured file client

### OpenVPN — `Tunnel\RemoteDesktop`

    openvpn.cmd -Root <data> -Connect          connect and wait for WORK disks via rclone
    openvpn.cmd -Root <data> -Disconnect       disconnect only the selected profile
    openvpn.cmd -Root <data> -Check -NoPause    validate paths and running GUI, no connection
    openvpn-path.cmd -Root <data>              choose client and, when needed, profile
    openvpn-path.cmd -Root <data> -ClientPath <exe> -Profile office.ovpn -NoPause

`TUNNEL -> NET -> OPENVPN` and `SETUP -> OTHER -> OVPN PATH` call these wrappers.
OPENVPN offers connect/open WORK or disconnect. Ctrl+OPENVPN performs `-Check`.
Implementation: `Engine\OpenVpn.ps1` and
`Tunnel\RemoteDesktop\Start-OpenVpn.ps1`, compatible with Windows PowerShell 5.1.
Profiles and credentials never enter the program directory. Default layout:

    DATA\OpenVPN Portable\openvpn-portable.exe
    DATA\OpenVPN Portable\app\...
    DATA\OpenVPN Portable\data\config\office.ovpn
    DATA\OpenVPN Portable\data\log\...
    DATA\OpenVPN Portable\data\audion-client.json
    DATA\OpenVPN Portable\office.rdp

The external client is supplied by the owner, including its drivers; Audion does
not install drivers, copy profiles into the system, edit routes or download OpenVPN.
Without a saved choice, installed OpenVPN GUI takes priority over the portable
launcher in DATA. An explicit saved choice wins; paths inside DATA are relative.
A single `.ovpn` is selected automatically; multiple profiles require selection.
System GUI receives DATA's config/log directories and its matching core path.
Portapps always appends its own config/log directories after user arguments, so
its launcher must be inside the selected DATA folder and uses its own `data\config`.
A manually chosen portable subfolder is supported; a portable outside DATA is
refused rather than silently connecting with its unrelated profile.
An existing GUI must have the same executable and explicit config directory.
For modern GUI versions that erase their command-line arguments, a direct GUI
launch records its PID, creation time, Windows session, executable and DATA/config
paths in DATA's `OpenVPN Portable\data\audion-instance.json`. All fields must
match the running process and current DATA; a stale PID, conflicting explicit
directory, copied/corrupt receipt or unreadable executable is refused. Repeated
IPC launches retain the first GUI's record. Portapps wrapper PIDs are not recorded.
Otherwise launch is refused without disconnecting any VPN. Launching is not
reported as an established connection. Connect (also the CLI default) requires
the selected DATA's configured `[work]` SFTP remote and trusted known_hosts_file.
It starts the external client through UAC and waits up to 90 seconds for a real
`rclone lsjson work:/` listing. The GUI then opens WORK in the original active
panel, unless the user switched DATA, section or panel source in the meantime.
Failure leaves VPN running and reports the rclone error; no host keys are accepted.
Disconnect uses the matching GUI's `--command disconnect <profile>` IPC only,
never disconnect_all or process termination. An unreadable elevated GUI requires
UAC inspection; an unrelated/unknown DATA is still refused. STOP stays a file
operation control. `-ResultPath` returns a per-invocation receipt in DATA runtime;
the GUI consumes it asynchronously and refreshes the network and WORK panels.
Multiple machines using the same certificate may displace one another; concurrent
use requires server-approved client profiles, not automatically changed settings.
The `.rdp` file is carried alongside the client and can be opened separately.
`Tests\Test-OpenVpn.ps1` uses synthetic DATA folders and an inert native client
to test relocation, selection, conflicts, CLI configuration, targeted disconnect,
native arguments, rclone readiness, rejected keys, invalid output and timeouts.

### Cloudflared — `Tunnel`

    check-tunnel-client.cmd         state of cloudflared and the ssh routes
    install-tunnel-client.cmd       install it and write the routes
    update-cloudflared.cmd          refresh the binary alone

### Colours — `Source\config`

    colors\themes.json              row colours of the dark and the light side, rule by rule
    mask-groups.json                what a family is: video, documents, archives

Rows are painted by the first rule that fits, top down, as in Total Commander:
the age rules stand above the type rules, so a fresh archive is painted as
fresh. A type rule names a family of `mask-groups.json` - the same families the
mask window and the search offer; the program keeps no second list of
extensions. The build copies both files into `App\config`. Window colours -
frames, buttons, list background - are the theme dictionaries of
`Source\App.axaml`; the four themes are picked from the menu of the sun button.

### Port forwarding — `Tunnel\RemoteDesktop`

    desktop-base.cmd                the desktop of BASE over ssh
    desktop-laptop.cmd              the desktop of LAPTOP
    web-router.cmd                  the home router's web page through BASE
    socks-base.cmd                  a SOCKS5 proxy into the home network

    Open-Forward.ps1 base desktop                          the same by hand
    Open-Forward.ps1 base web -RemoteHost 192.168.1.1      any web face
    Open-Forward.ps1 base port -RemoteHost X -RemotePort N any TCP port
    Open-Forward.ps1 base-cf desktop                       over a named route

The address after the first colon is resolved on the far side, so one machine
gives access to everything it can see. Nothing is added to the network stack:
no adapter, no routes, no DNS. The forward lives as long as the client window;
closing it drops the connection. The `ПРОБРОС` group of the `REMOTE` row runs the
same wrappers.

### Name resolution — `Runs`

    repair-dns.cmd                  look, then choose who resolves names
    repair-dns.cmd -Check           look only, change nothing
    repair-dns.cmd -Set cloudflare  set a resolver without asking

The `DNS` button in the `TUNNEL` row runs `Engine\Scripts\Repair-Dns.ps1`. It
reports what the adapters use, what the router offers over DHCP, who holds port
53 and who ends up asking outward — the last one found through
`o-o.myaddr.l.google.com` and named by its reverse record, so `dns.google` and
`one.one.one.one` identify themselves. Then it offers a choice: leave as is,
back to the router, or one of Cloudflare, Google, Quad9, Yandex, AdGuard. The
chosen one is asked for a name first and written only if it answered — a silent
resolver would leave the machine without names. A local resolver's service
(ControlD, YogaDNS, AdGuard, dnscrypt) is started if it is down. Tunnel adapters are left
alone: the tunnel sets DNS there itself.

The same button checks `NlaSvc` — the service that decides whether there is a
way out and draws the tray icon. With it stopped, sites open while Windows shows
"no internet", the connection profile sits on `LocalNetwork`, and the firewall
picks a profile blindly. The button puts the service back on automatic start and
starts it.

### Clouds — `Runs`

    clouds.cmd                      list what is connected
    clouds-add.cmd                  connect one; rclone asks and opens the browser
    clouds-remove.cmd               drop one from this machine
    clouds-check.cmd                knock on each and report who answers
    clouds-keys.cmd                 where the keys are and what protects them
    clouds-key.cmd                  store the cloud configuration password on this machine
    clouds-reconnect.cmd            renew sign-in for an existing cloud remote
    clouds-keys-where.cmd           machine, data folder and MAIN VPS side by side
    clouds-push.cmd                 put the config on MAIN VPS as the golden copy
    clouds-pull.cmd                 fetch it onto this machine, no sign-in again
    clouds-send.cmd -From a: -To b: move data cloud to cloud using MAIN VPS

The `CLOUDS` row runs the same `Engine\Scripts\Manage-Clouds.ps1`. Clouds do
not share `rclone.conf`: they live in `config\rclone\clouds.conf`, encrypted by
rclone, and the password for it sits in `clouds.key`, sealed by DPAPI to this
user and this machine. The password never appears on a command line — rclone
reads it from `RCLONE_CONFIG_PASS`, set for the duration of the call. Signing in
happens at the cloud: OAuth in a browser where the provider offers it, login and
password inside rclone's own console where it does not. Connected clouds appear
as panel sources next to the machines, so copying between two clouds is the
ordinary F5. Two accounts of the same provider get
`--server-side-across-configs` automatically: the bytes stay inside the provider.

The DPAPI seal is tied to this user and this Windows, the tokens are not. So
the golden copy of the config lives on MAIN VPS (`~/.audion/clouds.conf`, mode 600)
and the password lives in the data folder as `Tunnel\clouds.key` — MAIN VPS holds
the lock, the data folder holds the key. The file is plain text protected by
permissions only (owner, administrators, SYSTEM); together with the MAIN VPS copy
or any machine's `config\rclone\clouds.conf` it opens every cloud. EXPORT KEYS
and IMPORT KEYS do not carry it: on a fresh machine put `Tunnel\clouds.key` into
the data folder by hand, then run `clouds-pull.cmd`, and no cloud sign-in is
repeated.

### The tools the program carries — the root

    update-rclone.cmd               refresh rclone only
    update-terminal.cmd             refresh the portable terminal only

The window's `ОБНОВИТЬ` button runs `Engine\Scripts\Update-Tools.ps1` with no
switches, which does all three: cloudflared, rclone and the terminal. Add
`-Check` to only report versions, `-Force` to download even when the version
matches. Versions are asked for before downloading, so nothing is fetched twice;
the terminal's real release is kept in `Tools\terminal\.version` because
`wt.exe` reports the branch number instead.

Start with the safe modes: `-WhatIf` on the mirror and on peer issuing, `-Check`
on keys and tunnels. They write nothing.

## Setting up a machine

For an existing machine after reinstalling Windows, use `SETUP -> RESTORE`
or `Tunnel\RemoteDesktop\restore-machine.cmd -Root <data> -NoPause`.
Before formatting, run SSHD once on that machine: it saves the current host
identity in `DATA\Tunnel\SSHD`, separate from client golden copies and Export.
Restore stages that identity before installer/service start, imports keys,
connects profile SSH trust to DATA known_hosts, repairs lost paths and recreates
only the explicitly enabled persistent channel's Startup shortcut. It never
rescans or accepts changed host keys. Full contract: `Docs\RESTORE_EN.md` (Russian: `Docs\RESTORE_RU.md`).
Exit 1 means local setup failed; exit 2 means local setup completed but not all
configured SSH/SFTP routes responded. `-SkipProbe` omits network probes.

Two folders travel to a new machine, and the second one only in part:

    Audion Sync Tools            the program itself - window, scripts, Tools
    Audion Backup\Tunnel\SSH       the golden copy: machine key pairs and server keys
    Audion Backup\Tunnel\Export    Export Keys, when keys are carried from an old machine

Snapshots and mirrors are not carried: `SYNC ALL` fills them if this machine is
supposed to hold a mirror at all. Panels and console need only the two `Tunnel`
subfolders.

**A machine gets what it needs, not everything.** Copying the whole data
folder is the easy mistake: the work machine arrived with all six mirrors,
the MAIN VPS snapshot and - worse - SECOND VPS's own WireGuard configs,
private key inside, on a corporate machine in someone else's domain. What a
machine needs follows from what it may reach:

    Tunnel\SSH\clients      CLIENTS: public keys of the fleet - so its neighbours can enter it
    Tunnel\SSH\servers      only the keys to whichever of MAIN VPS and SECOND VPS
                             this machine actually uses
    Tunnel\Export           its own pair and the config, nothing of the neighbours'
    Tunnel\SSH\beacon       its own REVERSE SSH TUN key
    Tunnel\rclone           known hosts for the panels

The work machine reaches exactly two places, the laptop and home, so it holds
SECOND VPS's key and nothing else: no MAIN VPS, no Forgejo, no R2
credentials. Its `~\.ssh` is trimmed the same way. Whatever it does not use,
it should not be able to open.

Then, in this order (mode → group → button):

    1  SETUP → STEPS → DATA FOLDER        where Audion Backup lies; creates the skeleton, remembers the path
    2  SSH KEYS → LOCAL → SSH-KEYGEN      the key of THIS machine; the name is suggested from account + computer
    3  SETUP → STEPS → ADDRESSES…         addresses of the machines; a new target is written here
    4  SSH KEYS → EXTERNAL → SSH-KEYSCAN  collect the machines' host keys so panels recognise them
    5  SETUP → STEPS → RCLONE.CONF        build rclone.conf; asks only for the Cloudflare account id
    6  SSH KEYS → EXTERNAL → R2 CREDS     the R2 bucket pair, if this machine should see R2

One action lives in the TUNNEL mode: **TUNNEL → LOCAL → SSHD** turns on sshd
*on this machine*. It is needed not wherever others will reach in, but
where the machine does not accept files yet - no service, closed port. If its
panel already opens from another machine, the step is pointless: the public keys get
there by `SSH-COPY-ID` over ssh. Administrator rights, once per machine.

**A machine nobody can knock at.** Behind a corporate firewall or on mobile
internet `SSHD` changes nothing: the port may be open, but no packet reaches it.
Such a machine has to call out instead - a reverse ssh forward:

    Tunnel\RemoteDesktop\reverse-ssh-second-vps.cmd

It holds one outgoing ssh session and asks MAIN VPS or SECOND VPS to open a
port on its own loopback. Whoever is there reaches this machine through it.
Nothing is installed in the system: no adapter, no service, no routes taken
over - and that is the whole point. Since 09.09.2026 it hangs off SECOND VPS
by default: it is visible without a VPN, and `reverse-ssh-second-vps.cmd` names it
first.

First SSH contact needs host trust. REVERSE SSH TUN setup offers OpenSSH's
fingerprint confirmation in its console, then retries in strict batch mode.
Compare the SHA256 with the host key shown in the provider's server console.
Changed host keys are refused, never replaced; inspection, removal and redirected
input never open a confirmation dialog. Each setup writes
`logs\ssh-beacon-setup-<date>-<time>-<pid>.log`, retaining errors for every route.
SSH-KEYSCAN includes SECOND VPS and its configured SSH port, and writes the
panel list in machine data (`config\rclone\known_hosts`). GUI and
`Runs\ssh-keyscan.cmd -Root <data>` call `Engine\Scripts\Update-SshHosts.ps1`.
It runs outside the WPF dispatcher: a parallel direct scan and a parallel strict
SSH fallback each have a five-second deadline (`-TimeoutSeconds` overrides it).
The worker's job closes its ssh/proxy descendants on STOP or exit. Unanswered
hosts keep their keys; changed keys require Ctrl / `-Force` after verification.
The SSH profile is unchanged by the scan.

On `bad permissions`, interactive REVERSE SSH TUN setup reads effective
IdentityFile paths with `ssh -G` and repairs ACLs only within the selected data's
SSH/Export SSH folders or the current user's `.ssh`. It retries strict batch SSH
once. Inspection/removal do not repair ACLs. No private key bytes are changed.

**Configured REVERSE SSH TUN lifetime.** `Engine\BeaconLifecycle.ps1` is shared
by CLI launch and the GUI supervisor. The GUI restores saved state for the
current computer in the selected DATA folder; it never registers a key while
restoring. An active setup console pauses supervision. After that console
closes, the GUI starts a missing worker directly. Unexpected exits are logged
and retried after 30 seconds. GUI STOP suspends supervision for that window;
CLI `-Stop` and removal save `AutoStart=false`. Setup saves `AutoStart=true`.
LAPTOP remnants are not auto-started; explicit `Persistent=true` opts it in.
GUI setup adds `-Persistent`: a hidden WMI-launched worker stays outside the GUI
process tree, and a per-DATA `shell:startup` shortcut restores it at user sign-in.
Each worker owns a job for its SSH/proxy children and a mutex per machine/data
folder. Closing the GUI ends only its legacy nonpersistent workers.
The REVERSE SSH TUN button toggles configured state: disable removes the exact
startup link and stops only that DATA/name worker; enable reuses key/port/server.
Ctrl keeps the setup/check/remove wizard available. CLI has `-Resume`, `-Toggle`,
`-Persistent` and `reverse-ssh-toggle.cmd`. `-Stop` and removal disable startup
before stopping processes. No scheduled task, service, server key rotation or
new route is introduced on resume. The worker retries SSH interruptions; no
channel exists while asleep, powered off or before the user signs in.
The internal worker runs in inbox Windows PowerShell 5.1 using its absolute
system path (Sysnative for a 32-bit caller on 64-bit Windows). This makes host
selection deterministic; it is not a confirmed fix for the Windows 10 startup
failure. The affected machine reported the same fatal Process.Start(ssh) exit
under both PS 7.6.0/.NET 10.0.5 and PS 5.1. A contained ssh -V in an ordinary
PS 5.1 console succeeded; that does not prove a hidden full tunnel can start.
GUI and CLI use the same host selection. GUI runtime and SSH routes are unchanged.
`Tests\Test-BeaconLifecycle.ps1` exercises these paths with synthetic native
processes, a local OpenSSH version query and the actual -Hold entry point with
full tunnel arguments and a synthetic local ProxyCommand. The latter verifies
live diagnostics and SSH/proxy cleanup without real profiles or network access;
it does not test authentication or successful remote forwarding. A dummy
`usr\bin\ssh.exe` put first in PATH checks that the worker takes the ssh of Windows,
not an MSYS build (the ssh of Git in Git Bash cannot read the BOM of the config).
Each worker also receives a unique `*.trace.log`: synchronous checkpoints
record its PowerShell/CLR version, resolved SSH binary, child PID, and the last
completed startup/read step. They contain no SSH argument list or key contents.
The GUI reports the exit code in decimal and hex and shows the last checkpoint
when a worker exits silently. Empty stdout/stderr alone cannot identify a crash.

**Why not a WireGuard tunnel.** It solved the same task and cost far more: an
adapter and a service inside Windows, routes taken over, its own DNS, a fight
with the purchased VPN over a shared driver, and a crash at boot while the
network is not up yet. A machine that was supposed to become reachable would
lose its own network instead. The tunnels that stayed are the ones nothing can
replace: `wg1` on the BASE router, through which SECOND VPS sees the home
network, and `WG BASE-ROUTER`, when the whole home network is needed at
full speed.

**No Windows scheduler.** A task fires at logon and rests: the process dies and
nobody raises it, while the task still reads `Ready`. On a laptop a closed lid
adds to that. Anything recurring lives as a systemd timer on MAIN VPS: it puts
the nightly backup into R2, and each machine fetches it on its own, the way the
laptop does - MAIN VPS never comes to a machine. Something that must come up
with the machine gets a shortcut in `shell:startup` or is started by hand.

When every machine has its own key, from any of them:

    7  SSH KEYS → AUTHORIZED_KEYS → SSH-COPY-ID   writes the public keys from CLIENTS to every reachable machine
    8  check                                      open the BASE panel and the MAIN VPS console - the new key works
    9  SSH KEYS → AUTHORIZED_KEYS → REVOKE        pick the key by its button - the old shared one is `machines`

Step 9 is guarded: a machine where the revoked key would be the last one is
skipped, so revoking cannot lock you out. Revoking the key of the machine you
are sitting at needs a separate confirmation.

## Names: BASE, HOME, WORK

One word used to mean two things, and it cost hours. `home` was both the route
to the main router and a machine at another site. The words now follow the
machines:

    base            the BASE site: the desktop BASE and router-base with the WG server on it
    home            the HOME machine, reached like the work one
    work            the work computer
    router-base     the BASE router - it runs the WG server, others only connect
    router-home     the HOME router - WireGuard there is a client, nothing listens
    WG BASE-ROUTER        the route into the BASE network, service WireGuardTunnel$base

BASE is the only place that accepts an incoming tunnel; HOME and WORK are seen
through SECOND VPS, exactly like any machine with a REVERSE SSH TUN.

## How the keys are laid out

One pair per **client machine**, not one pair for the whole fleet:

    ~\.ssh\<name>_ed25519               the working private key
    Tunnel\SSH\clients\<name>_ed25519   the recovery copy in machine data
    Tunnel\SSH\clients\<name>.pub       public half; <name>_ed25519.pub is also supported
    authorized_keys on every target      one line per client machine

On Windows that file is `C:\ProgramData\ssh\administrators_authorized_keys`, not
`.ssh\authorized_keys`: `sshd_config` sends the Administrators group there
(`Match Group administrators`), and the owner's accounts are administrators.
`setup-ssh-server.cmd`, `SSH-COPY-ID` and `REVOKE` write exactly that file; on
MAIN VPS and SECOND VPS the keys stay in `~/.ssh/authorized_keys`.

`setup-ssh-server.cmd` does not only append. A line labelled with a machine from
CLIENTS (`Tunnel\SSH\clients`) but carrying another key is replaced with the key
from CLIENTS, missing keys are added, a repeated key collapses into one line.
Lines of machines CLIENTS does not know stay and are named by their label: CLIENTS
is per machine, and the neighbours' `SSH-COPY-ID` brings them past it.

A lost laptop is struck out with one button (`REVOKE`, then its own key), and
every other machine keeps working. The older scheme - one shared
`audion_machines` pair copied to every client - is gone: it was revoked on
7 September 2026, and it could only ever be revoked by replacing the key
everywhere at once. Nothing in the code looks for it by name any more; where a
key of this machine is needed, it is found through CLIENTS: the public key lies in
`clients`, and the private key next to it and in the profile.

MAIN VPS keeps its own key (`audion_vps_root_ed25519`): its `authorized_keys`
is filled through the provider panel, not by our scripts.

CLIENTS is per machine: `Tunnel\SSH\clients` lives in the data folder, and
that folder is separate on every machine. A key created here does not appear
in the neighbour's CLIENTS, so `SSH-COPY-ID` carries public keys over ssh straight
into the targets' `authorized_keys` - and it runs **from** the machine whose
key was just created. Made a key on BASE, press SSH-COPY-ID on BASE.

REVERSE SSH TUN has a key of its own - a separate ssh pair, not the machine key - and
it lives by the same rule, on its own machine:

    Audion Backup\Tunnel\SSH\beacon\<name>_beacon_ed25519      the private key, never leaves
    Audion Backup\Tunnel\SSH\beacon\<name>_beacon_ed25519.pub  the public key
    Audion Backup\Tunnel\SSH\beacon\<name>.beacon.json         port on MAIN VPS or SECOND VPS, hosts, the host in use
    Audion Backup\Tunnel\SSH\beacon\beacon-<name>.sshconfig    its own ssh config for those hosts

On MAIN VPS or SECOND VPS the key lives in the `tunnel` account - a system
account of its own with no shell, a locked password and nothing in its home but
the key file, so a stolen tunnel key reaches nothing of the working account. It
is created by hand once per server; until it exists, registration says so and
changes nothing. What the server allows it ships as
`Tunnel\RemoteDesktop\config\sshd-tunnel.sample.conf`. There the public key is
written as
`restrict,port-forwarding,permitlisten="127.0.0.1:<port>",permitopen="127.0.0.1:<port>",command="/bin/false"`:
it may listen only on its own loopback port and connect only back to it - no
shell, no other forwards. Unix-socket forwarding is not closed by key options:
that is `AllowStreamLocalForwarding` on the VPS itself. The tunnel to the BASE router keeps its config by
the same rule, in `Audion Backup\Tunnel\WG`.

Names come from a person and land in file names and in labels on every machine,
so only lowercase latin, digits, dash and underscore are allowed. The wizard
does not refuse a bad one - it translates it (`Мой ПК` becomes `moy-pk`) and
asks whether to save it that way.

## Filling the program with data

Setting up gives access; the folders are still empty. What follows is the order
that fills them, and where each thing lands.

    UPDATE            TUNNEL → NET               the three carried tools: cloudflared, rclone, terminal
    PORT 22 TCP PING  TUNNEL → NET               which routes are alive right now; colours the indicators
    DIAGNOSTICS       TUNNEL → NET               the full picture, report into logs\routes-*.log
    DRY RUN           STORAGE → MAIN VPS MIRROR  what would be updated; touches nothing
    SYNC ALL          STORAGE → MAIN VPS MIRROR  full recovery + auto-discovered repository library
    RELEASE           STORAGE → UPLOAD TO R2     the folder with the private archives
    DRY RUN           STORAGE → UPLOAD TO R2     what would go into the R2 bucket
    PRIVATE BACKUP    STORAGE → UPLOAD TO R2     uploads the private Build-stack archives

Nothing is scheduled on the machine: MAIN VPS takes its nightly snapshot by a
timer of its own, and the mirror is refreshed by SYNC ALL or `sync-backup.cmd`.
A daily task left by earlier versions is deleted by REMOVE TASK in SETUP, shown only while the task exists.

Where it lands in the data folder:

    Snapshots\                 canonical recovery tar, checksum, complete readable recovery view
    Forgejo Mirror\            every repository, all refs/HEAD verified, Git fsck
    <known project folders>    MIR of Git source + selected published data; explicit protectedLocal only
    Repositories\<owner>\      new/unmapped repositories, automatic working copies
    Recovery\sync-all\sync-all-<id>\ durable staging/rollback until success, then JSON proofs only
    Tunnel\SSH, Tunnel\Export  keys - filled during setting up, not here

Plan v2 lives in DATA `config\mirror.json`; the program ships only a template
without a value of any household (`config\mirror.sample.json`, every value a <...>).
`forgejo` defines owners, repository root, URL and DATA identity/trust paths;
`sources` maps Git projects and payload views; `coverage` defines the archive
layouts for operational verification. Read [SYNC ALL](Docs/SYNC_ALL_EN.md)
before changing this flow. No plan, a v1 plan or a <...> left in it stops SYNC ALL
before any write: the engine never builds or finishes a plan from the program. A new
machine copies the plan from the DATA of a machine where SYNC ALL has run.
Always MIR: server versions replace local edits/extras inside managed library
folders. protectedLocal explicitly preserves secrets; Tunnel, connection config
and full recovery Snapshots are outside deletion. before is temporary rollback,
removed after successful verification along with old SYNC ALL caches. A write-ahead
journal and OS lock protect replacements; changes during staging stop the run.
No restore, collector, publication or model call belongs in this action.

Scratch is disposable in both program and DATA after the GUI and CLI workers stop.
Only DATA/config holds cloud session.conf (with its source checksum) and BISYNC pairs/listings;
BISYNC without DATA is refused, not saved in a public program config. DATA/Recovery holds
restore backups, conflicts and legacy runtime copies; Recovery/sync-all holds the durable
journal/rollback. Program Recovery is binary rollback only (App/Tools). StorageLayout.ps1
does verified offline migration; Initialize-DataFolder invokes it on preparation. The manual
door is Engine/Scripts/Migrate-RuntimeStorage.ps1 -Root <DATA> [-IncludeProgram].
Do not migrate program state into an unrelated one-run -Root or another machine's DATA.
Tests/Test-RuntimeStorage.ps1 and the headless stand delete scratch and check reopening;
the Python suite checks interrupted SYNC ALL recovery with no scratch left.
No separate conflict override: MIR is permanent. Self-contained local mirrors with exactly current
refs/HEAD and a successful fsck can supply cached objects; origin remains the server.

Two things are worth doing in the safe mode first: both `DRY RUN` buttons in STORAGE.
SYNC ALL's DRY RUN reads the real Git catalog over SSH and writes nothing in DATA;
PRIVATE BACKUP's DRY RUN reads its archive inputs and bucket listing.

The mirror does not need to live on every machine. A laptop that only reaches
files needs steps 1-6 of setting up and nothing from this list.

## Checks

**Which PowerShell runs all this** — the one the program carries, `App\AudionPs.exe`
(PowerShell 7 inside the program). Every wrapper - `Runs\*.cmd`, `Tunnel\*.cmd`,
`Tunnel\RemoteDesktop\*.cmd` - and every step of `builder_main.cmd` starts it; a wrapper
says so and exits with 1 when `App\` is not there. `builder_main.cmd build_app` makes
`App\` with plain `dotnet`: the one step that cannot use it. `Start.exe` in the root is
the launcher of the window: it starts `App\AudionSyncTools.exe` with the same arguments
(`--no-admin` skips the question of administrator rights; `-Root "<data folder>"` names the
data folder of this run and leaves the pointer of the program alone). It is compiled by
`Engine\Launcher\Build-StartExe.ps1` with the csc.exe of .NET Framework - run it under
`App\AudionPs.exe`; `Start.exe --self-test` returns 0 when the window is in place.
One thing stays on the PowerShell of the system: the worker of REVERSE SSH TUN. The previous
window (WPF in PowerShell) was removed on 05.10.2026. The functions of the engine its module
held - targets, keys, tunnels, the data pointer - are `Engine\BackupEngine.psm1` now: no window
in it, the scripts of `Engine\Scripts` and the tests import it.

**Do the self-tests pass under it** — `Tests\Run-Tests.ps1`. Runs every
`Tests\Test-*.ps1` the way the builder does (`-File`, the exit code decides), a line a
test; what each one printed stays in `._runtime\tests\<shell>`. `-Only Cli,Targets`
runs the named ones, `-Shell pwsh.exe` the same under another PowerShell, to compare.
`Cli`, `Test-Cli` and `Test-Cli.ps1` name the same test. A name that fits nothing ends with 1:
it used to end with «all passed» over zero tests. The last line says how many passed - 32 now.

    App\AudionPs.exe -NoProfile -ExecutionPolicy Bypass -File Tests\Run-Tests.ps1

**Does a script end with its own code** — `Tests\Test-ScriptExit.ps1`. A wrapper starts a script
with `-File`: the code is the number of its own `exit`, and 0 when it ran to its end. The window
starts it through `-Command` (`Source\Core\Scripts.cs`, `Inner`) and a step of RESTORE through
`-EncodedCommand` (`Restore-Machine.ps1`, `Invoke-RestoreStep`). Both used to end with
`exit $LASTEXITCODE`, and that variable also holds the code of the last program the script started
itself: a script that dealt with a refusal of ssh and ended without an exit of its own was «code 3»
in the window and failed RESTORE as a step. The success of the call (`$?`) tells the two apart - it
is false only after an exit that is not zero. The check takes both commands out of the two files as
they are written and runs them on probe scripts against `-File`. A script the window starts may
end without an `exit`; a wrapper of your own must not end with `exit $LASTEXITCODE`.

**Does a script see the refusal of a program it started** — `Tests\Test-NativeRefusal.ps1`. The
other side of the same rule: the code of a script being its own, a refusal of `icacls` or `git`
left unlooked at is «ready» everywhere - the window used to show it now and then, by chance, as
the code of the last program. Where such a refusal decides what the script reports, the script
looks at `$LASTEXITCODE` itself. The check runs `Export-AudionKeys.ps1` for real, twice - with the
real `icacls` and with a stub of it that refuses - in a sandbox: a profile, a data folder and a
key of its own in the temporary folder of the system (the home of a child PowerShell follows
`USERPROFILE`, `HOMEDRIVE` and `HOMEPATH`), the real profile never read. The other places -
`New-ClientKey.ps1`, `Import-AudionKeys.ps1`, `Install-OpenSSH.ps1`, `Manage-Clouds.ps1` - by
reading. A new call of a program whose failure would turn a report into a lie gets its check.

**Is a downloaded tool checked before it is started** — `Tests\Test-ToolTrust.ps1`. The program
runs with administrator rights and downloads its tools; what it downloads is checked before the
first start: the tunnel client - a signature of Cloudflare (`Update-Tools.ps1` and
`Tunnel\Install-TunnelClient.ps1`), Windows Terminal and Microsoft Edit - a signature of
Microsoft; rclone, micro and PeaZip, which their publishers do not sign - the SHA-256 of the
archive against the file of sums the publisher lays beside the release (`SHA256SUMS` in the folder
of the version of rclone, `<asset>.sha` beside the asset of micro, `SHA256.txt` of the release of
PeaZip): a sum that differs refuses the archive, a sum that is not found is said and the install
goes on. The check takes `Assert-Publisher` and `Assert-PublisherSum` out of `Update-Tools.ps1` and
`Install-Tools.ps1` and tries them on files every machine with the program has. A new tool gets its
check before its first `--version`. The versions stay the latest: nothing is pinned.

**Does every button reach a script that is there** — `Tests\Test-Cli.ps1`. Reads the sources of
the window (`Source\*.cs`) as text and launches nothing. Every script and wrapper the window calls
must lie on disk and must know the switches it is called with: an unknown switch stops a script at
binding, before its first line. The data folder must reach the functions that look for it. And the
other way round: a script of `Engine\Scripts` or a wrapper no button reaches must be named in the
test with its reason - a new one without a button and without a reason fails it.

**The SETUP wizards from a console** — each wizard of the new window is a dialog plus a script of
`Engine\Scripts`, and the script works alone: `Set-Targets.ps1 -AnswerFile <json>` (ADDRESSES),
`New-ClientKey.ps1 -Name <machine>` (SSH-KEYGEN), `Build-Transport.ps1 -Account <id> -Profile <name>`
(RCLONE.CONF), `Set-R2Credentials.ps1` with `ABK_R2_ID` and `ABK_R2_SECRET` in the environment (R2 CREDS),
`Set-RouterSecret.ps1 -Router router-base` with `ABK_ROUTER_PASSWORD` (ROUTER PASS),
`Get-BeaconState.ps1` (the state of REVERSE SSH TUN, JSON). `-Describe` prints what a wizard shows
before it asks. Every one takes `-Root <data folder>`; a secret is never an argument.

**Is a data folder ready before the first button** — `Initialize-DataFolder.ps1 -Root <data folder>
[-Previous <the folder left>]`. No button calls it: the window does, at its start, when another data
folder is chosen and before the ADDRESSES wizard on a folder without addresses. It lays out
`targets.json` from `Tunnel\RemoteDesktop\config\targets.sample.json` where there is none (a file
that is there is never replaced), brings in the entry of SECOND VPS from `~\.ssh\config`, and moves
the working files a version before 1.15.0 left in the program folder; with `-Previous` what belongs
to another machine goes to `Recovery\migrated-*` of the data instead. One line of JSON:
`moved`, `quarantined`, `quarantine`, `targets`, `second`. `-SshConfig <file>` names another ssh
config - `Tests\Test-DataFolder.ps1` runs the script whole on a throwaway data folder with an empty one.

**What the dots of the buttons show** — `Get-SetupState.ps1 [-ClientName <name>] [-ArchiveRoot <folder>]` and
`Get-BeaconState.ps1`: one line of JSON each, nothing is changed, no network is touched. A dot is grey when
the thing is not there, green when it is; the keys, the addresses, the transport and the pair of R2 stay
amber until a panel was read through them.

**The summary of the state in the journal** — `Get-StateSummary.ps1`. One line of JSON, nothing is
changed: the latest archive of `Snapshots`, the pair of R2, the version of cloudflared, sshd,
WG BASE-ROUTER, the tunnel clients, and every tunnel service of this machine - up or down, ours or
of another VPN, the last handshake, the answer of the far end, a client that is gone. The window
writes it as `===== СОСТОЯНИЕ =====` and `===== ТУННЕЛИ =====` in the language of the window: at its
start, by the СОСТОЯНИЕ button, when another data folder is chosen. A tunnel is ours when its config
lies in `Tunnel\WG` of the data folder; only such a tunnel is pinged, once and inside itself.
`Tests\Test-StateSummary.ps1` runs the script whole on a throwaway data folder.

**Keys, tunnel and clouds from a console** — the same split. `Manage-ClientKeys.ps1 -Inventory`
(LIST), `-Spread` (SSH-COPY-ID), `-Revoke <name>` (REVOKE); `-WhatIf` says where the work would
go and stops, `-Lan base,home` names the machines to be called `<name>-lan`, `-ClientName` marks
the key of this machine. `Get-TunnelState.ps1 -Clients | -Tunnel | -Peers -Router <key> -Address <ip>`
answers in JSON and changes nothing; `Switch-Tunnel.ps1 [-Force]` is the power of WG BASE-ROUTER.
`Get-Clouds.ps1 -Kinds | -List | -Save -Session <file>`; its `-Open` prints the password of the
session config for the window alone - never run it into a file or a journal.
Every edit of clouds by `Manage-Clouds.ps1` ends with a push of `clouds.conf` to MAIN VPS: do not
run it on a throwaway data folder.

**The keys of the new window** — F2 rename, F3 links, F4 edit, Shift+F4 a new file, F5 copy, F6 move,
F7 folder, F8 / Del delete (on a disk of this machine - into the Recycle Bin), Shift+F8 / Shift+Del
past the bin, F11 copy, F12 mirror, Alt+F5 pack, Alt+F9 unpack, Tab the other panel,
Ctrl+U swap the panels, Alt+F1 / Alt+F2 the sources of the left / right panel, F the quick filter,
Ctrl+F / Alt+F7 the search window, Esc stops a running job - from the panels, not from a text field
(else closes the filter, the found list or SETTINGS), Ctrl+Shift+N / Ctrl+Shift+P names / paths into the clipboard. In a panel: Enter, Backspace, Space / Insert mark, Num * invert, Ctrl+A mark all (again -
none), Ctrl+R reload, Home / End and Left / Right the ends of the list, Alt+Left / Alt+Right back and
forward, Shift+Space exact bytes, Ctrl+Enter a terminal.

**Search** — Ctrl+F, Alt+F7 or the magnifier between the panels: from the place of the active panel
downwards, by one `rclone lsjson -R`. A word is a part of the name, `.dwg` a type, `2026-*` a mask,
`/…/` a regular expression; groups of extensions and the time narrow it. GO TO FILE opens the folder of a
found file; TO PANEL shows the found files in the active panel as a flat list - F5 / F6 keep their
folders on the other side, Esc brings the folder back.

**Masks** — the asterisk between the panels: a free field (masks separated by commas; a word is a part
of the name, `.png` an extension, `readme.md` a whole name), one's own sets as buttons (kept in
`config\mask-sets.json` of the data folder), the time of the change, the groups of
`Source\config\mask-groups.json` as chips. Masks mark rows; they do not filter a copy.

**Do LIST, SSH-COPY-ID and REVOKE do what they say** — `Tests\Test-ClientKeys.ps1`. These are never tried
on real machines. The script `Manage-ClientKeys.ps1` runs whole against a stub of ssh: the
authorized_keys of every "machine" is a file in a temporary folder, a machine without a file is silent.
Checked: a missing key is added and a foreign line stays, a second run adds nothing, a revoked key leaves
every machine but the one where it is the last, `-WhatIf` writes nothing.

**Does the window hold together** — `Tests\Test-NewWindow.ps1`. The names of the markup are
checked by the compiler; the data is not. Every button of `Source\config\bars.json` must have a
`case` in `MainWindow*.cs`. Every Russian caption, hint and tooltip of the rows and of the
markup must have an English pair in `Source\config\i18n.json` - and so must every Russian text
in quotes in the code of the window: a line without a pair stays Russian in the English window
and is noticed at the first error only. What is not shown to a person - a sample for measuring
a column, a tag the log knows its lines by - is named in the test with its reason. Two steps
look at the guard: `Core\CrashGuard.cs` is switched on before the window is made, writes
`logs\gui-crash-<time>.log` and keeps the window. The last steps hold in place what the previous
window did by itself and the move to Avalonia lost without a sound (the audit of 06.10.2026):
the routes are read from the plain `rclone.conf` (`Rclone.TransportPath`), never from the
encrypted config of a cloud session; closing the window asks about a running job and stops it
with its children and the queue (`JobRunner.StopForClose`); `--server-side-across-configs` goes
to COPY, MIRROR and BISYNC between two clouds of one kind; the data folder changes in one step
with nothing awaited between the pointer and the panels, its cloud session closed before it;
`-Root` on the command line of the window names the data folder; the version number is one,
`config\version.json` - the build project reads it, and a built `App\` must carry the same.

**Does an action go with what it began with** — the same test, its last steps (the second audit
of 06.10.2026, AST-M07). An action that waits - for a count, for a script, for an answer to its
question - begins with `using var pending = Pending();`: while one is pending, and while any
question of the window is on the screen, `ChooseDataFolder` refuses as it does while a job runs.
The test walks every `async` method of `Source\MainWindow*.cs`: each either holds the data folder
so, or is named in the test with the reason it need not - a new method with an `await` and with
neither fails it. The address of an operation is asked of the place taken before the question
(`Place.Of(panel)` in `MainWindow.Ops.cs`), never of the panel after it: the search window is not
blocked by a question of the main one and sends the panel elsewhere. A reading asked of the old
data folder - the probe, the state, the summary - compares the folder after its `await`.

**Does the window keep what the previous one did by itself** — in the Debug copy, on throwaway data
folders only (`dev-run.ps1 -Data <folder>`): `data=<another folder>` changes the data folder as
SETTINGS does and `say` tells where the active panel stands after it; `clouds=say` names the
config and the session rclone is run with; `job=<seconds>|<file>` queues a job that waits and
then writes the file, `close=1` presses the cross, `answer=yes|no` answers its question - the
file must not appear after a "yes".

**Does the window behave between an await and its answer** — `Tests\Stand\Run-Stand.ps1`, the
stand. A step of the Debug copy answers a question at once, and the tests read the code as text:
neither sees what happens while a question waits - and that is where both audits of the move to
Avalonia found their seven defects with every check passed. The stand is the built
`App\AudionSyncTools.dll` under Avalonia.Headless, no screen and no mouse, with
`Tests\Stand\Worker.cs` in place of `AudionPs.exe` and `rclone.exe`: it reaches nothing, writes
down what it was called with and answers what a probe needs. The probes are
`Tests\Stand\Harness.cs`: a question is left open, the data folder is changed or a panel is sent
elsewhere (`panel.Go(...)`, as the search window does), and only then the question is answered;
what the stub of rclone was called with is the verdict. Twenty-five probes, a line each: the routes
under an encrypted cloud session, closing during a job, a job that left a helper behind with its
output open, the flag between two clouds of one kind,
the change of the data folder with its session and panels, the frame of the addresses (the real
`Initialize-DataFolder.ps1` under the real PowerShell of the program, on a throwaway folder and
with an empty ssh config), COPY being counted and MIRROR being asked while the folder is changed,
F8 F5 F2 F7 after the panel went elsewhere, the summary of the old folder, the first start, `-Root`;
and seven for what the review of 08.10.2026 and the audit of its fixes found: СТОП between the two
halves of one action, F2 onto a taken name and by the case alone, F8 and
the Recycle Bin, a folder inside a folder (with a real junction, and the loopback as "this machine
over ssh"), Esc from a text field, VIA MAIN VPS, a pair of BISYNC by two roads; and six for what
the audit of those fixes found: a name taken while F2 waited in the queue with a folder that
stayed in place and the temporary name said, this very machine by a far road (asked by its mark,
silent, another machine, remembered, paths that do not meet), the warning of rclone hidden in one
job, the name an object is left under after СТОП, СТОП while a job asks before its start, a panel
that left a folder of this disk; and one for the probe of the network: both VPS silent (in 192.0.2.0/24)
while a router of the network answers (a listener on the loopback) - the probe is tried again, and a
probe asked while one runs goes after it. The stub reads a folder of the stand for real when asked for a
listing, answers `lsjson-answer.json` for any other place, fails by `lsjson-fail`, `moveto-fail`
and `moveto-fail-second` (the second step of a rename alone), really renames on a disk by
`moveto-real`, answers the reading of the mark by `cat-self` (this machine) and `cat-silent` (no
answer), says the warning of rclone by `say-ssh-over-host`, and writes down the variables that lay
a road over a remote as `env:NAME=VALUE`. A probe that uses a member the window got with its fix
reaches it by its name (`typeof(Job).GetProperty(...)`): the same probes must build against the
window before the fix, or `-Dll` cannot show that they fail there.

What the stand cannot see is what rclone then does to the files: it compares what rclone was
called with. All six findings of that review were of the other kind - rclone, called just so,
deletes what the question did not name. An operation that deletes or overwrites is tried with the
rclone of the program on throwaway folders, and the verdict is what the folders hold afterwards.
A server of its own for that: `rclone serve sftp <folder> --addr 127.0.0.1:<port> --user u --pass p
--authorized-keys "" --dir-cache-time 0s --vfs-cache-mode off` (two ports - two roads to one
machine), `rclone serve s3` for a place without a rename of its own. The name of a remote must be
longer than one letter: `m:` is the disk M: to rclone under Windows.

    App\AudionPs.exe -NoProfile -ExecutionPolicy Bypass -File Tests\Stand\Run-Stand.ps1

It needs the dotnet SDK and a built `App\`, builds two programs in a temporary folder of the system
and takes about two minutes; it is not a part of `Run-Tests.ps1`. The exit code is the number of
probes that failed. `-Dll <file>` names another build of the window - the copy in the folder of an
audit shows what was before a fix, and that a probe can fail at all; `-Keep` leaves the stand. A
probe calls the window by the names of its private methods: a renamed method stops the build of
the stand, and the script says so. Run it after any change of a handler that awaits.

**Does an error close the window** — in the Debug copy only: `dev-run.ps1 -Dev "crash=ui"` and
`crash=async` throw on purpose, in a handler and after an `await`. The window must stay, the
log must get one red line an error, and `logs` one `gui-crash-*.log` an error.

**Does a target edit stay inside its own entry** — `Tests\Test-Targets.ps1`.
The address wizard edits `targets.json` as text rather than rebuilding it from
an object: rebuilding would lose the key order and the explanations the file is
written for. The test edits a copy and checks that neighbours, comments, line
count and BOM survive. It also moves SECOND VPS over from an old ssh
config, follows `Include`, and checks the port and the host names.

**Does sshd follow CLIENTS** — `Tests\Test-SshServerKeys.ps1`. Runs the real
`Merge-AccessKeys` from `Setup-SshServer.ps1` on made-up lines: an old key of a
machine from CLIENTS is replaced, a missing one is added, a neighbour's key
stays, one public key under two file names gives one line, an empty CLIENTS
changes nothing.

**Is rclone.conf built from the template** — `Tests\Test-Transport.ps1`.
Builds `rclone.conf` from `config\rclone.sample.conf` into a temporary file and
checks the substitutions, the section list and that unfilled placeholders are
named rather than silently written out. A rebuild with `-KeepFrom` keeps a
working line whose placeholder has nothing to fill it.

**Does REVERSE SSH TUN stop, delete and report honestly** — `Tests\Test-Beacon.ps1`.
Synthetic processes and a fake ssh only: a key pair comes out without a passphrase
and a locked one is recognised; a single tunnel process leaves together with its ssh and
a refused ssh stop is a failure; inspection and removal go to the hosts from the
tunnel's state, and "no key here" from a place where the key was never registered is not a removal; the
window's indicator counts only the tunnel's own ssh, not a matching port number.


**Does the first SSH connection work safely** — `Tests\Test-SshBootstrap.ps1`.
Uses synthetic ssh and known_hosts to exercise new-host confirmation, refusal,
changed keys, redirected input, fallback errors, failed commands with numeric
stdout, and GUI delegation to the scan worker. Does not contact any machine or read the
real SSH profile. Run under both Windows PowerShell 5.1 and PowerShell 7.

**Do SSH ACL repair and scan cancellation work** — `Tests\Test-SshRecovery.ps1`.
Uses temporary synthetic files with real Windows ACLs, checks import precedence,
host-key preservation, parallel deadlines and child cleanup when the worker stops.
It never connects to a real machine or changes profile keys. Run under both shells.

**Is the network healthy at all** — `check-routes.cmd`. One run answers
everything: which of the four routes live and how fast, whether ssh reaches a
greeting, whether the catalogue reads, whether the tunnel to the BASE router
has a handshake, what port the router listens on and when its peers last spoke,
and whether MAIN VPS and SECOND VPS themselves can see home. That last line
separates "our network is broken" from "home is broken".

**Is a route usable right now** — the probe line in the window header:
`дом 1 мс · MAIN VPS 90 мс · cloudflare 57 мс · SECOND VPS 45 мс · окно 4 мс · путь:
ДОМ (по пробе)`. A number means the port answered, not that the protocol will
pass: filtered networks reset ssh after the connection is established, and a TCP
probe cannot see that. `нет` means silence. The last figure is the window's own
lag, measured in the same run — when everything looks slow, it says whether the
network or the window is to blame.

**Is a tunnel actually alive** — the power button next to `WG BASE-ROUTER`: green
while the tunnel's interface is up. The indicator beside the wizard answers another
question - whether the tunnel is installed at all: the service can run while the
adapter is disabled. `REVERSE SSH TUN` itself toggles enabled state; Ctrl opens
the wizard. Its indicator is green while an
ssh process holds the forward to the port from the tunnel's state file and
OpenSSH logs its remote-forward acknowledgment (new workers), amber
when the tunnel is set up but the channel is down. Whether the port on MAIN VPS
or SECOND VPS listens is answered by `reverse-ssh-check.cmd`, not by the window.

**Which route a panel is using** — the source button says so: `BASE`,
`BASE · MAIN VPS`, `BASE · MAIN VPS CF`, `BASE · SECOND VPS`. The caption and
the actual choice come from the same function, so it cannot lie.

**Did a transfer really finish** — the terminal prints `rclone` statistics every
five seconds and the exit code at the end. `0 B / 0 B` is not proof of failure:
creating empty directories moves no bytes.

## Configuration

Connection files below are relative to the selected machine data folder:
`config\rclone\*`, `config\mirror.json`, and `Tunnel\RemoteDesktop\config\targets.json`.
Templates, themes, version and GUI preferences remain in the program. What a
person made in the window lies in data as well and outlives a cleanup of the
program: the sets of masks and the pairs of BISYNC.
Legacy conflicts are preserved under `Recovery\migrated-<time>-<id>` in data,
never over an existing working file. IMPORT KEYS restores flat SSH exports and
the `clients`/`servers` subfolders, including both client public-key names. Auto
prefers Export Keys but supplements missing server pairs from golden
`Tunnel\SSH\servers`; it does not supplement neighbouring CLIENTS private keys.
Existing private destinations and selected sources have their ACLs checked and
repaired without changing key bytes. `-Check` changes neither bytes nor ACLs.

    config\rclone\rclone.conf        remotes: base, laptop and their route variants, r2 buckets
    config\rclone\r2.credentials     R2 keys, read through AWS_SHARED_CREDENTIALS_FILE
    config\mask-sets.json            the sets of masks saved in the mask window (data)
    config\bisync\pairs.json         the pairs of BISYNC, for a person to read (data)
    config\bisync\state\<id>\        what rclone keeps for one pair, its --workdir (data);
                                     a pair is known while its two listings are there
    Source\config\colors\themes.json row colours of both sides, rule by rule
    Source\config\mask-groups.json   the families of masks: rows, the mask window, search
    Source\config\bars.json          the rows of buttons of every section
    Source\config\i18n.json          the English pair of every Russian caption
    Source\App.axaml                 window palettes: the theme dictionaries
    config\version.json              the project's version stamp
    config\gui-settings.json         what the window remembers: archive root, terminal, bisync pairs

    Tunnel\RemoteDesktop\config\targets.json        machine addresses and ports
                                                    base, laptop, router, and the
                                                    empty ones: home, work, router-home, router-work
    Tools\terminal\.version                         the terminal's real release
    Audion Backup\Tunnel\WG\<name>.*               tunnels with a private key inside:
                                                    the way home to the BASE router
    Audion Backup\Tunnel\RemoteDesktop\config\router-<name>.secret
                                                    router password by the name of the router:
                                                    base64, portable with the data folder - not
                                                    DPAPI, which did not survive a reinstall

    ~\.ssh\config                    hosts: base-lan, base-direct, base-cf, base, second-vps-cf

Remotes and ssh hosts are paired by name: `base-direct:` uses `ssh base-direct`,
which jumps through `audion-vps-direct`. Changing a route means changing both.

**Ports in use:** router WG server `500/udp`, SECOND VPS's own tunnel home
`8443/udp`, cloudflared `443/tcp`
to Cloudflare. High ports are filtered almost everywhere; `443/udp` is where QUIC
lives and is inspected on purpose; `500/udp` is IPsec and usually passes.

## Traps already stepped on

- A parameter declared `[string]$Service` and a local `$service = Get-Service …`
  are the same variable — PowerShell ignores case — so the object was coerced to
  a string and `.Status` came back empty. Name the local something else.
- A `List[object]` returned from a function is unrolled into the pipeline, and an
  empty one becomes `$null`; wrap the return as `,$items`. Likewise a single
  element comes back as itself: wrap the call in `@(...)`.
- `Start-Process -ArgumentList` joins the array with spaces and quotes nothing:
  a path holding «Audion Sync Tools» split in two and curl printed the archive
  into the window. Quote such arguments yourself.
- `api.github.com` allows sixty requests an hour per address and then answers
  403; read the latest tag from the redirect of `/releases/latest` instead.
- `Get-PSDrive -PSProvider FileSystem` returns PowerShell's own `Temp` drive;
  `rclone` then looks for a remote called `Temp` and fails. Keep single-letter
  drives only.
- A comma binds tighter than `+` in PowerShell: `'A: ' + $x, 'B'` parses as
  `'A: ' + ($x, 'B')` and collapses the whole array into one string. Wrap every
  element of an array that contains `+` or `-f` in brackets.
- `$switch` is a reserved automatic variable; assigning to it fails elsewhere.
- Markup (`.axaml`) is XML: a comment cannot contain a double dash and an
  attribute value cannot contain `<` — a tooltip mentioning `<date>` breaks the build.
- Reading a remote panel must not happen on the window thread: through two jump hosts
  it takes ten seconds and the window turns white. Read in a separate process,
  off the window thread.
- A redirected stream that nobody reads wedges the child process forever; an open
  stdin makes `ssh` inside `rclone` wait for an answer nobody will give. Read
  both streams asynchronously and close stdin.
- The network probe finishes *after* the first panel read, so the chosen route
  must be part of the read key — otherwise the panel keeps knocking at an address
  this network does not have.
- A drive root needs its slash: `E:` means "current folder on that drive". For
  ssh, `remote:/` lists drives while `remote:` opens the home folder.
- `rclone` prints progress only with `--stats-log-level NOTICE`.
- For `rclone` only files exist: an empty directory is neither created nor
  deleted without `--create-empty-src-dirs`.
- Transfers pass `--metadata` so creation and access times survive — local to
  local only; the sftp backend reports no metadata at all.
- Windows OpenSSH refuses SETSTAT on directories, which `rclone` counts as an I/O
  error and then skips all deletions. Pass `--no-update-dir-modtime` whenever a
  side is an ssh machine.
- A folder emptied over sftp may refuse `rmdir` while Windows still holds the
  deleted files open. Every call passes `--retries-sleep 5s`; deletion over ssh
  raises `--retries` to 6.
- Multi-threading hurts on the far routes: 1.65 MiB/s with one stream against
  815 KiB/s with eight. Do not add `--multi-thread-streams`.
- The router speaks NDMS: `GET /auth` answers 401 with realm and challenge, then
  `SHA256(challenge + MD5(user:realm:password))` is posted back. CLI commands go
  to the RCI root as `{"parse": "..."}` in an array. A client tunnel also listens
  on a port, so a WG server is told apart by `server-owned`; `allow-ips` lives in
  `show/running-config`, not in `show/interface`; and `show/ndns` keeps `name`
  and `domain` apart.
- WireGuard has no portable build on Windows: the tunnel is a service and the
  adapter is a signed driver.
