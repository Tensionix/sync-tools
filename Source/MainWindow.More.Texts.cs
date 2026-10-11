namespace AudionSyncTools;

/// <summary>
/// The texts of the wizards of TUNNEL, CLOUDS and SSH KEYS. A Russian text is the key of its
/// English pair in config/i18n.json: change a letter here - change the key there, or the
/// translation is lost. They came letter for letter from the WPF window this one replaced.
/// </summary>
public partial class MainWindow
{
    // Peer
    const string PeerWhich = "На каком роутере выписываем?";
    const string PeerTaken = "НА РОУТЕРЕ ВЫПИСАНЫ: {0}";
    const string PeerFree = "СВОБОДЕН: {0} - его и займёт новый пир";
    const string PeerCount = "пиров на роутере: {0}";
    const string PeerSilentNote = "РОУТЕР НЕ ОТВЕТИЛ: кто выписан - неизвестно. Адрес роутер назначит сам, но проверить его отсюда нечем; пароль вносится кнопкой ROUTER PASS.";
    const string PeerSilent = "роутер: молчит";
    const string PeerHead = "Кому выписать конфиг WireGuard?";
    const string PeerNameLabel = "ИМЯ ПИРА: латиница в нижнем регистре, цифры, тире, подчёркивание";
    const string PeerShow = "ТОЛЬКО ПОКАЗАТЬ";
    const string PeerShowNote = "Команды печатаются, в роутер ничего не уходит.";
    const string PeerWrite = "ВЫПИСАТЬ";
    const string PeerWriteNote = "Пир заводится на роутере, конфиг ложится в данные рядом с ключами.";
    const string TunnelWhere = "КУДА: роутер BASE, на нём WG-сервер";
    const string PeerPairNote = "Ключевая пара родится здесь: роутер получит только публичный ключ. Имя станет подписью пира на роутере и именем файла конфига.";
    const string PeerTitle = "ПИР {0}: {1}";
    // RouterCheck
    const string CheckWhich = "Какой роутер осматриваем?";
    const string CheckTitle = "РАЗГОВОР: {0}";
    // Wg
    const string NotInstalled = "не установлен";
    const string WgAwgNote = "Туннели пойдут на AmneziaWG: он на машине первый, и драйвер в системе один на всех. Ставить второй клиент не нужно - он отобрал бы туннель у чужого VPN.";
    const string WgHaveNote = "Клиент на месте, ставить нечего.";
    const string WgHead = "Клиент туннелей";
    const string WgClose = "ЗАКРЫТЬ";
    const string WgJournalHead = "===== КЛИЕНТ ТУННЕЛЕЙ =====";
    const string WgNoneNote = "Ни одного клиента нет - без него туннели не поднять. Поставим обычный WireGuard: он свой, ни от кого не зависит и ставится через winget.";
    const string WgInstall = "ПОСТАВИТЬ";
    const string WgInstallTitle = "УСТАНОВКА WIREGUARD";
    // Tun
    const string TunService = "служба: {0}";
    const string TunNotMade = "не заведена";
    const string TunName = "имя: {0}";
    const string TunAddress = "адрес: {0}";
    const string TunConf = "конфиг: {0}";
    const string TunHandshake = "рукопожатие: {0}";
    const string TunPeerAlive = "дальний конец {0}: отвечает за {1} мс";
    const string TunPeerSilent = "дальний конец {0}: молчит";
    const string TunRoutesNote = "Через туннель пойдут только перечисленные сети, остальное - мимо. Целая подсеть забирается вся: если машина стоит в ней же, её принтеры и общие папки уедут в туннель. Тогда пишите отдельные адреса - 192.168.1.10/32.";
    const string TunHead = "Туннель до роутера BASE";
    const string TunUp = "ПОДНЯТЬ";
    const string TunUpNote = "Поставить службу и открыть маршрут в сеть BASE. Поднимать потом - кнопкой питания.";
    const string TunBoot = "ПОДНЯТЬ ВСЕГДА";
    const string TunBootNote = "То же самое, но туннель встаёт и сам, при каждой загрузке машины. Для той, до которой не дотянуться рукой.";
    const string TunCheck = "ПРОВЕРИТЬ";
    const string TunCheckNote = "Ничего не менять: показать службу, рукопожатие и видимость сети BASE.";
    const string TunDown = "СНЯТЬ";
    const string TunDownNote = "Убрать службу и её маршруты. Конфиг остаётся, поднять можно снова.";
    const string TunFileHead1 = "# Что этот туннель ведёт в себя: одна сеть на строку.";
    const string TunFileHead2 = "# Всё, чего здесь нет, идёт мимо туннеля - это и есть сплит-туннелинг.";
    const string TunFileHead3 = "# Отдельная машина пишется с /32: 192.168.1.10/32";
    const string TunRoutesSaid = "[туннель] в туннель ведут: {0}";
    // Hand
    const string HandNever = "не здоровались";
    const string HandSeconds = "{0} с назад";
    const string HandMinutes = "{0} мин назад";
    const string HandHours = "{0} ч назад";
    // CloudAdd
    const string CloudAddHead = "Какое облако заводим";
    const string CloudAddNote1 = "Вход происходит на стороне самого облака: где есть OAuth — в браузере, где нет — логином и паролем.";
    const string CloudAddNote2 = "Программа не видит ни логина, ни пароля: ей достаётся только ключ доступа, и он ложится в зашифрованный файл.";
    const string CloudOauth = "вход в браузере";
    const string CloudPassword = "логин и пароль";
    const string CloudNameHead = "Как назовём это облако";
    const string CloudNameOk = "ЗАВЕСТИ";
    const string CloudNameNote1 = "Имя встанет подписью кнопки над панелью. Латиницей, без пробелов: его же видит rclone.";
    const string CloudNameNote2 = "Второй аккаунт того же облака назовите иначе — скажем, drive-work.";
    const string BadName = "[окно] имя не годится: {0}";
    const string CloudOpening = "[облака] открываю окно входа: {0} как {1}";
    // CloudRename
    const string CloudNone = "[облака] ни одного не заведено";
    const string CloudRenameHead = "Какое облако переименовать";
    const string CloudRenameNote = "Имя - это подпись кнопки над панелью и имя remote для rclone. Токен остаётся прежним: входить заново не придётся.";
    const string CloudNewHead = "Новое имя облака";
    const string CloudRenameOk = "ПЕРЕИМЕНОВАТЬ";
    const string CloudLatinNote = "Латиницей, без пробелов.";
    const string CloudRenameTitle = "ОБЛАКА: ПЕРЕИМЕНОВАТЬ";
    // CloudSend
    const string CloudSendNeedsBoth = "[облака] MAIN VPS перегоняет только между облаками: откройте облако в обеих панелях";
    const string CloudSendTitle = "ПЕРЕГОН СИЛАМИ MAIN VPS";
    const string CloudSendHead = "Скопировать из левого облака в правое силами MAIN VPS?";
    const string CloudSendNote1 = "Копирует сам MAIN VPS: берёт у одного облака и отдаёт другому. Ничего не удаляется.";
    const string CloudSendNote2 = "Работа идёт на MAIN VPS и от окна не зависит: СТОП её не остановит, окно можно закрыть. Ход показывает clouds-send.cmd -Watch.";
    const string CloudSendOk = "ПЕРЕГНАТЬ";
    // CloudSource
    const string CloudTip = "Облако {0}, заведено как {1}. Ключ доступа лежит здесь зашифрованным; сам аккаунт программа не видит.";
    // Spread
    const string SpreadEmpty = "[ключи] в CLIENTS пусто - нажмите SSH-KEYGEN";
    const string SpreadHead = "SSH-COPY-ID: ключи машин";
    const string SpreadNote = "Публичные ключи из CLIENTS будут дописаны в authorized_keys на этих машинах. Существующие строки не трогаются: старый доступ продолжит работать, пока вы сами его не отзовёте.";
    const string SpreadCount = "КЛЮЧЕЙ В CLIENTS: {0}";
    const string SpreadMine = "{0}: это текущая машина - публичные ключи сюда кладёт SSHD";
    // Revoke
    const string RevokeNone = "[ключи] отзывать нечего: публичных ключей не найдено";
    const string RevokeMineMark = " — эта машина";
    const string RevokeSharedMark = " — старая схема";
    const string RevokeMineNote = "Ключ машины, за которой вы сидите: после отзыва она перестанет открывать остальные.";
    const string RevokeSharedNote = "Общий ключ старой схемы: один на весь парк, отзывается целиком.";
    const string RevokeKeyNote = "Публичный ключ машины {0} из CLIENTS.";
    const string RevokeHead = "Отозвать ключ";
    const string RevokeOk = "ОТОЗВАТЬ";
    const string RevokeNote = "Публичный ключ будет убран из authorized_keys на всех машинах, куда есть доступ. Машина, где после этого не останется ни одного ключа, пропускается: закрыть себе вход отзывом нельзя.";
    const string RevokeSureHead = "Это ключ той машины, за которой вы сидите";
    const string RevokeSureOk = "ВСЁ РАВНО ОТОЗВАТЬ";
    const string RevokeSureNote = "После отзыва эта машина перестанет открывать остальные: ни панели, ни консоль работать не будут, пока не заведёте новый ключ кнопкой SSH-KEYGEN и не пропишете его кнопкой SSH-COPY-ID.";
}
