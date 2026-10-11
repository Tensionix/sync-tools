# A prompt for an assistant: setting up Audion Sync Tools on a new machine

This file is what to show a language model when it helps you install the
program on yet another computer. First the ready-made request, then the
reference: what happens at every step and where it all ends. The Russian
version is [PROMPT_RU.md](PROMPT_RU.md).

---

## The request

> Help me set up Audion Sync Tools on this machine. The program sits next
> to this file; the window opens with `Start.exe`. What
> I need is for this machine to open files on my other machines and in the
> Cloudflare R2 buckets.
>
> Work in the window step by step — each step names its mode — and after each
> step tell me what came out of it. Do not go around the wizards: they write
> into the same files, but they check what was written and say what went
> wrong.
>
> The order is:
>
> 1. SETUP → `DATA FOLDER` — I will point at the data folder (`Audion Backup`).
> 2. SSH KEYS → `IMPORT KEYS` — lay the carried keys out into this machine's own places.
>    They travelled inside Export Keys, but cannot work from there: ssh looks for
>    them in the profile, rclone in its own folder.
> 3. SSH KEYS → `SSH-KEYGEN` — create the key of this machine. A name will be
>    suggested; if you propose your own, it must be lowercase latin.
> 4. Do not raise a tunnel on this machine. If nobody can knock at it from
>    outside — a corporate firewall, mobile internet, a grey address — what it
>    needs is a reverse SSH tunnel: `Tunnel\RemoteDesktop\reverse-ssh-second-vps.cmd`.
>    That holds one outgoing socket and changes nothing in the system. A WG
>    tunnel, by contrast, installs an adapter and a service, takes over routes
>    and fights the purchased VPN over a shared driver — that is how a machine
>    loses its own network.
> 5. SETUP → `ADDRESSES…` — check the machine addresses, fill in what is missing.
> 6. SSH KEYS → `SSH-KEYSCAN` — collect the host keys so the panels recognise the machines.
> 7. SETUP → `RCLONE.CONF` — build rclone.conf. It needs the Cloudflare account id;
>    I will give it.
> 8. SSH KEYS → `R2 CREDS` — I will type the R2 bucket pair myself, just tell me when to
>    open the form.
> 9. TUNNEL → `SSHD` — only if this machine does not accept
>    files yet: no service, closed port. If its panel already opens from other
>    machines, skip the step. It asks for administrator rights, that is expected.
> 10. SSH KEYS → `SSH-COPY-ID` — write the public keys onto the machines.
>
> Then check it: open a panel of another machine and the MAIN VPS console. If
> something stays silent, say what exactly, and do not fix it blindly.

---

## What to carry to the machine

Two folders, the second one only in part:

    Audion Sync Tools            the program: window, scripts, tools
    Audion Backup\Tunnel\SSH       the golden copy of the keys: machine key pairs and server keys

Snapshots and mirrors are not carried - `SYNC ALL` fills them if this machine is
supposed to hold a mirror at all. Without the SECOND VPS key from `Tunnel\SSH`,
REVERSE SSH TUN cannot register itself there, so `Tunnel\SSH` travels every time,
even when the machine only needs its panels.

## What happens at every step

**The data folder.** Program and data live apart: the program folder holds
the window and the scripts, the data folder holds snapshots, mirrors and the
keys. The wizard remembers the path and creates an empty skeleton
inside. The `-Root` switch at startup outranks the remembered path — that is
for when there is more than one data folder.

**Laying the keys out.** Export Keys travels as a folder, but each program looks
for keys in its own place: ssh in the user profile, rclone in `config\rclone`.
This step lays what arrived into those places and rewrites the recorded paths
for wherever the folder now lives. Skip it and the panels stay silent while
`ssh` complains about a missing key that is in fact lying right there.

**The machine key.** Every machine has its own pair. The private key stays
here and never travels; the public key goes into CLIENTS
(`Tunnel\SSH\clients`), and `SSH-COPY-ID` writes it onto the machines. The machine name becomes
the key file name and the label in `authorized_keys` on every target — the
machine is later revoked by that name.

What you type is not rejected: `Мой ПК` becomes `moy-pk`, and the wizard asks
whether to save it that way.

**A machine nobody can knock at.** It calls out itself - with a reverse ssh
forward: `Tunnel\RemoteDesktop\reverse-ssh-second-vps.cmd`. It holds one outgoing
connection and asks MAIN VPS or SECOND VPS to open a port on their side; whoever
enters there reaches the machine through that port. Nothing appears in the
system: no adapter, no service, no routes taken over - and that is its main
virtue.

A WG tunnel to SECOND VPS used to stand here. It solved the same task and
cost the machine its own network: an adapter and a service take over
routes, set their own DNS and fight the purchased VPN over a shared driver.
On 09.09.2026 it was removed everywhere - from the program, from the
machines and from SECOND VPS.

A machine behind a router that itself holds a tunnel to SECOND VPS needs none
of this: it is already visible at its local address through SECOND VPS. That is how the desktop
at home lives.

**Addresses.** They live in `targets.json`. The wizard edits one entry
without touching its neighbours or the explanations, and knocks on the port
right away: an address without a check is a record, not a connection.

**Host keys.** These are the fingerprints of the machines themselves; the
panels use them to tell the real machine from a substituted one. The file is
the program's own — `config\rclone\known_hosts`; the user's
`~\.ssh\known_hosts` is left alone, `ssh`, Windows Terminal and Tabby use it.

**rclone.conf.** `rclone.conf` is built from the template
`config\rclone.sample.conf`. Addresses, accounts and keys are filled in by
the window; only the Cloudflare account id is asked for. Anything unfilled
stays in the file as `{{NAME}}` and is named out loud — a half-built
rclone.conf is visible at once.

**R2 CREDS.** The id and secret pair from the Cloudflare panel is written
as `r2.credentials`. Right after writing, the window asks R2 for its
bucket list. The values never reach the log — the assistant will not see them, and
that is by design.

**SSHD.** Needed not where others will reach in, but where the machine
does not accept files at all yet: no service installed, port closed. If its
panel already opens from another machine, the step is pointless. It places the
public keys from CLIENTS into C:\ProgramData\ssh\administrators_authorized_keys: for an
account in the Administrators group sshd reads keys only there, not from
.ssh\authorized_keys. It also opens port 22 not to the whole world but to your
own networks. The single place where administrator rights are
asked for.

**Every machine has its own CLIENTS.** `Tunnel\SSH\clients` lives in the data
folder, and that folder is separate on every machine: a key created here will
not appear in the neighbour's CLIENTS. That is why `SSH-COPY-ID` writes the public keys
over ssh, straight into the targets' `authorized_keys`. `SSH-COPY-ID` runs **on**
the machine whose key was just created: made a key on BASE — press it on
BASE.

**SSH-COPY-ID.** Writes the public keys onto the machines over access that already
works. Access does not appear out of nothing: if a machine cannot be entered,
the wizard says so. Existing lines are untouched — the old access keeps
working until it is revoked.

---

## Where it ends

The panels open files on other machines, on MAIN VPS and in five R2 buckets;
copying runs between any two sides. The console opens from a machine button.
Mirrors and snapshots are a separate story — they live in the STORAGE
section and are not needed on every machine: a laptop that only fetches files
is done with the steps above.

When there is more than one machine, each one repeats the same, and then, from
any of them, `SSH-COPY-ID`. Once every machine has its own key, the shared key
of the old scheme is revoked with `REVOKE`: it shows the keys as buttons, and
the shared one is labelled as the old scheme.

---

## What the assistant must not do

- **Do not edit keys.** The owner edits them. The assistant may diagnose
  without reading the values.
- **Do not revoke anything before the new access is verified.** The order is
  only: `SSH-KEYGEN` → `SSH-COPY-ID` → verify by logging in → revoke.
- **Do not run the window as administrator.** Exactly one action needs those
  rights (`SSHD`), and it asks for them itself.
- **Do not fix things around the wizards.** Editing `targets.json` or
  `rclone.conf` by hand is possible, but then nobody checks what was written,
  and the mistake surfaces an hour later as a silent panel.
- **Do not delete data.** The data folder holds the only local copy of
  MAIN VPS and the keys.
