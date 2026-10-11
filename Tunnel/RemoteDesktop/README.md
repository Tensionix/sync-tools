# Audion Remote Desktop

**Рабочий стол, файлы и порты своих машин — напрямую или через свои MAIN VPS
и SECOND VPS.**
*Desktop, files and ports of your own machines — directly or through your own
MAIN VPS and SECOND VPS.*

> **Рабочий стол по RDP ещё ни разу не проверялся.** Сценарии `connect-*` и
> `desktop-*` написаны, но живой сессии ещё не было.
>
> *The RDP desktop has never been tried: the `connect-*` and `desktop-*` scripts
> exist, but no live session has happened yet.*

---

## Что это / What it is

**RU.** Набор сценариев, чтобы добраться до своих машин откуда угодно: открыть
рабочий стол, забрать или положить файлы, донести до себя любой порт — веб-морду
роутера, сетевую папку, камеру. Кнопки окна Audion Sync Tools зовут эти же
сценарии, поэтому всё, что есть в окне, повторяется из консоли.

Маршрут выбирается сам, в таком порядке:

1. **Напрямую** — по местному адресу машины (`lan` в `targets.json`). Работает в
   той же сети и когда поднят путь домой — туннель до роутера BASE.
2. **Через MAIN VPS** — готовыми хостами из `~\.ssh\config`: `<машина>-direct`
   по его имени, `<машина>-cf` поверх cloudflared и `<машина>-ssh`, если
   машина держит свой REVERSE SSH TUN.
3. **Через SECOND VPS** — временным пробросом до адреса машины с его стороны.
   Адрес, имя хоста, ключ и учётная запись SECOND VPS берутся из записи
   `second` в `targets.json`.

Через SECOND VPS идут последним намеренно: чувствительное через него не ходит.

**EN.** Scripts to reach your own machines from anywhere: open a desktop, take or
put files, carry any port to yourself — a router's web page, a network share, a
camera. The Audion Sync Tools window calls these same scripts, so everything in
the window can be repeated from a console.

The route is picked on its own, in this order: **directly** by the machine's
local address (`lan` in `targets.json`) — in the same network or with the way
home up; **through MAIN VPS** by ready hosts from `~\.ssh\config`
(`<machine>-direct`, `<machine>-cf` over cloudflared, `<machine>-ssh` when the
machine holds its own REVERSE SSH TUN); **through SECOND VPS** by a temporary
forward to the machine's address as it sees it. SECOND VPS's address, host
name, key and account come from the `second` entry of `targets.json`.
SECOND VPS comes last on purpose: sensitive traffic does not go through it.

---

## Двойной клик / Double-click

| Что | Обёртка |
|---|---|
| **Рабочий стол** (RDP, ещё не проверялся) | |
| BASE или LAPTOP, маршрут выбирается сам | `connect-base.cmd`, `connect-laptop.cmd` |
| BASE или LAPTOP прямо по местному адресу, без проверок | `connect-base-lan.cmd`, `connect-laptop-lan.cmd` |
| BASE или LAPTOP пробросом по ssh, без туннеля | `desktop-base.cmd`, `desktop-laptop.cmd` |
| **Файлы** (SFTP) | |
| Файлы BASE, LAPTOP, HOME | `files-base.cmd`, `files-laptop.cmd`, `files-home.cmd` |
| Накопители, воткнутые в роутер BASE | `files-router.cmd` |
| Включить sshd на этой машине | `setup-ssh-server.cmd` |
| **Проброс** | |
| Веб-морда роутера BASE через BASE | `web-router.cmd` |
| SOCKS5-прокси в сеть BASE | `socks-base.cmd` |
| **Путь домой** (WireGuard до роутера BASE) | |
| Поставить сам WireGuard | `install-wireguard.cmd` |
| Выписать этой машине конфиг, заведя пира в роутере | `new-router-peer.cmd` |
| Поднять туннель из конфига | `setup-base-vpn.cmd` |
| Поговорить с роутером по API, только чтение | `check-router.cmd` |
| **REVERSE SSH TUN** (машина зовёт наружу сама) | |
| Поднять через SECOND VPS — быстрее | `reverse-ssh-second-vps.cmd` |
| Поднять через MAIN VPS — приватнее | `reverse-ssh-main-vps.cmd` |
| Показать или удалить | `reverse-ssh-check.cmd`, `reverse-ssh-remove.cmd` |
| **Проверка** | |
| Все маршруты к BASE, отчётом в `logs\routes-*.log` | `check-routes.cmd` |

*EN: desktop — `connect-*`, `connect-*-lan`, `desktop-*`; files — `files-*`,
`setup-ssh-server`; forwards — `web-router`, `socks-base`; the way home —
`install-wireguard`, `new-router-peer`, `setup-base-vpn`, `check-router`;
REVERSE SSH TUN — `reverse-ssh-*`; the route check — `check-routes`.*

---

## Цели / Targets

**RU.** Машины и роутеры описаны в `config\targets.json`. Пока своего файла нет,
окно разворачивает его из `config\targets.sample.json` при первом запуске, а
адреса вписывает кнопка `АДРЕСА`. В сборку едет только образец: карта чужого дома
в архиве не нужна.

    base, laptop, home, work        машины: lan и host, порты рабочего стола и файлов, user
    router-base, router-home, ...   роутеры: только файлы, вход паролем (keyAuth=false)
    server                          MAIN VPS: sshHost - имя хоста из ~\.ssh\config
    second                          SECOND VPS: host, sshHost, sshHostCf, key, user

`lan` — адрес для прямого маршрута, `host` — адрес той же машины со стороны
SECOND VPS; у домашних машин это обычно один и тот же адрес. `hint` — что
сказать, когда цель молчит.

**EN.** Machines and routers are described in `config\targets.json`. Until one
exists, the window lays it out from `config\targets.sample.json` on first run, and
the `ADDRESSES` button writes the addresses. Only the sample ships: nobody needs a
map of someone else's home in an archive. `lan` is the address for the direct
route, `host` is the same machine as SECOND VPS sees it; `server` names
MAIN VPS by `sshHost`, `second` holds the SECOND VPS address, host names, key and
account.

---

## Файлы / Files

**RU.** Файлы ходят по SFTP теми же маршрутами, что и рабочий стол. sshd
включается один раз на каждой машине, чьи файлы нужны: `setup-ssh-server.cmd`
включает sshd (OpenSSH Server), который уже есть в Windows отдельным компонентом, и
открывает порт 22 только своим сетям. Вход — ключом машины из профиля
(`~\.ssh\<машина>_ed25519`); публичные ключи своих машин сценарий прописывает
на этой машине из CLIENTS — `Tunnel\SSH\clients`. Ключа нет — `sftp` спросит пароль учётной
записи Windows. Если стоит WinSCP, откроется он, иначе штатный `sftp`.

Проверить, не меняя: `setup-ssh-server.cmd -Check`. Выключить: `-Remove`.

**EN.** Files travel over SFTP by the same routes as the desktop. Turn sshd
on once per machine with `setup-ssh-server.cmd`: it enables the
OpenSSH server that ships with Windows and opens port 22 to your own networks
only. Login uses the machine's own key from the profile; the script writes the
public keys of your machines from CLIENTS, `Tunnel\SSH\clients`. WinSCP opens
if it is installed, the built-in `sftp` otherwise.

---

## Диски роутера / The router's own disks

**RU.** `files-router.cmd` открывает накопители, воткнутые в сам роутер BASE, а
не файлы компьютеров. Две особенности:

* порт 22 у роутера открыт всегда — это его SSH-консоль, поэтому проверка
  доступности скажет «путь есть» и при выключенной передаче файлов. Передача
  включается в настройках роутера переключателем «SFTP-сервер»; без него `sftp`
  отвалится с жалобой на subsystem;
* вход — паролем учётной записи роутера (`admin`), тем же, что в его
  веб-интерфейсе. Ключ машины роутеру не предлагается.

**EN.** `files-router.cmd` opens the storage plugged into the BASE router itself.
Port 22 is always open there — it is the SSH console — so the reachability probe
says yes even with file transfer off (the router's "SFTP server" switch turns it
on); login uses the router's own `admin` password, not a machine key.

---

## Путь домой / The way home

**RU.** Туннель WireGuard от этой машины до WG-сервера на роутере BASE. Пока он
поднят, сеть BASE видна так, будто машина стоит там: и рабочий стол, и файлы идут
напрямую.

    install-wireguard.cmd        поставить WireGuard, если его ещё нет
    new-router-peer.cmd -WhatIf  показать, что будет сделано
    new-router-peer.cmd          завести пира в роутере и собрать конфиг
    setup-base-vpn.cmd           поднять туннель; -AtBoot - вместе с машиной

Конфиг может выдать и сам роутер: в его настройках WG-сервера добавляется
клиент, и `setup-base-vpn.cmd` подхватит свежий `.conf` из «Загрузок» или по
ключу `-From`. Через туннель заворачиваются только сети из
`Audion Backup\Tunnel\WG\routes.txt`, обычный интернет идёт как шёл; весь трафик
— ключом `-FullTunnel`, осознанно. Перед подъёмом сценарий предупреждает, если
адрес самой машины попадает в заворачиваемые сети. Пароль роутера `check-router.cmd`
спрашивает один раз; с ключом `-Remember` он сохраняется зашифрованным под эту
учётную запись и эту машину.

Посмотреть: `setup-base-vpn.cmd -Check`. Снять: `setup-base-vpn.cmd -Remove`.

**EN.** A WireGuard tunnel from this machine to the WG server on the BASE router.
While it is up, the BASE network is visible as if the machine stood there.
`install-wireguard.cmd` installs WireGuard, `new-router-peer.cmd` adds a peer on
the router and assembles the config (or take the file the router itself issues),
and `setup-base-vpn.cmd` raises the tunnel. Only the networks listed in
`Audion Backup\Tunnel\WG\routes.txt` go through it; `-FullTunnel` sends
everything, deliberately.

---

## REVERSE SSH TUN

**RU.** Машина, до которой не достучаться — за корпоративным файрволом, на
мобильном интернете, — зовёт наружу сама: держит одно исходящее соединение ssh и
просит MAIN VPS или SECOND VPS открыть у себя порт на localhost. Кто вошёл туда,
попадает через этот порт на машину. В системе при этом ничего не ставится: ни
адаптера, ни службы, ни маршрутов.

    reverse-ssh-second-vps.cmd  через SECOND VPS: быстрее и из дома без VPN
    reverse-ssh-main-vps.cmd    через MAIN VPS: дольше, зато трафик не идёт через SECOND VPS
    reverse-ssh-check.cmd       показать, что заведено, ничего не меняя
    reverse-ssh-remove.cmd      удалить: канал, ключ на MAIN VPS или SECOND VPS и локальные следы

**EN.** A machine nobody can knock at calls out instead: it holds one outgoing ssh
session and asks MAIN VPS or SECOND VPS to open a port on its own loopback.
Nothing is installed in the system. `reverse-ssh-second-vps.cmd` goes through
SECOND VPS, `reverse-ssh-main-vps.cmd` through MAIN VPS; `reverse-ssh-check.cmd`
shows it and `reverse-ssh-remove.cmd` deletes it.

---

## Пароль и учётная запись / Password and account

**RU.** Рабочий стол всегда просит вход той машины, к которой подключаешься, — не
MAIN VPS, не SECOND VPS и не туннеля. Если на машине учётная запись Microsoft:
логин — почта аккаунта (или `MicrosoftAccount\почта`), пароль — полный пароль
аккаунта, а не PIN: PIN и Windows Hello по RDP не работают. При первом
подключении `mstsc` предупредит о самоподписанном сертификате — это нормально.

**EN.** The desktop always asks for the target machine's own Windows sign-in. With
a Microsoft account the username is the account email (or
`MicrosoftAccount\email`) and the password is the full account password — not the
PIN, which does not work over RDP. The first connection warns about a self-signed
certificate; accept it.

---

## Проверить, ничего не открывая / Dry check

    connect-base.cmd -Check       видна ли цель и каким маршрутом
    files-base.cmd -Check
    setup-ssh-server.cmd -Check
    setup-base-vpn.cmd -Check
    reverse-ssh-check.cmd
    check-routes.cmd              все маршруты к BASE разом, с отчётом

`-Check` показывает, но ничего не открывает и не меняет.

---

## Состав / What is in the box

    Connect-Desktop.ps1    рабочий стол цели: сам выбирает маршрут
    Connect-Files.ps1      файлы цели по SFTP: сам выбирает маршрут
    Open-Forward.ps1       проброс порта по ssh: desktop, web, socks, port
    Setup-SshServer.ps1    sshd на этой машине
    Setup-BaseVpn.ps1      путь домой: туннель до роутера BASE
    New-RouterPeer.ps1     пир в роутере и конфиг для этой машины
    Check-Router.ps1       разговор с роутером по API, только чтение
    RouterNdm.psm1         вход в API роутера и запросы к нему
    Setup-SshBeacon.ps1    REVERSE SSH TUN этой машины
    Check-Routes.ps1       проверка всех маршрутов к BASE
    *.cmd                  обёртки для двойного клика, по одной на действие

    config\targets.json          цели: адреса, порты, учётные записи - у каждого свои
    config\targets.sample.json   образец целей, едет в сборку
    config\version.json          метка папки

Ключи и конфиги туннелей лежат не здесь, а в папке данных (`Audion Backup`):
`Tunnel\SSH` — ключи ssh, `Tunnel\WG` — конфиги WireGuard и `routes.txt`,
`Tunnel\RemoteDesktop\config\router_*.secret` — пароль роутера, зашифрованный под эту
учётную запись и машину. Путь к
ней считается от расположения сценариев, буква диска нигде не зашита.
