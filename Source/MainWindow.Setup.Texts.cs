namespace AudionSyncTools;

/// <summary>
/// The texts of the SETUP wizards. A Russian text is the key of its English pair in
/// config\i18n.json: change a letter here - change the key there, or the translation is lost.
/// They came letter for letter from the WPF window this one replaced (removed 05.10.2026).
/// </summary>
public partial class MainWindow
{
    // Targets
    const string CellAddress = "АДРЕС ИЛИ ИМЯ ХОСТА";
    const string CellUser = "УЧЁТНАЯ ЗАПИСЬ";
    const string CellPort = "ПОРТ";
    const string SecondHostLabel = "SECOND VPS: ИМЯ ХОСТА В ~\\.ssh\\config";
    const string SecondCfLabel = "SECOND VPS: ИМЯ ПОВЕРХ CLOUDFLARED";
    const string SecondKeyLabel = "SECOND VPS: ИМЯ КЛЮЧА В Tunnel\\SSH\\servers";
    const string TargetsHead = "Адреса машин";
    const string TargetsOk = "ЗАПИСАТЬ";
    const string TargetsAddressNote = "Адрес - там, где машина стоит: домашний адрес для домашних машин, внешний - для MAIN VPS и SECOND VPS. Как добираться, программа решает сама.";
    const string TargetsSecondNote = "SECOND VPS: адрес и порт в строке таблицы, имена его хостов и ключ - в полях под ней. В ~\\.ssh\\config их вписывает кнопка УСТАНОВИТЬ в разделе SETUP.";
    const string TargetsPortNote = "Порт 22 - это ssh. Не путайте с 3389: тот для удалённого рабочего стола и здесь не нужен.";
    const string TargetsEmptyNote = "Пустую строку можно оставить пустой - к ней просто не будут ходить.";
    // ClientKey
    const string KeyHead = "Ключ этой машины";
    const string KeyOk = "ЗАВЕСТИ";
    const string KeyNameLabel = "ИМЯ МАШИНЫ: латиница в нижнем регистре, цифры, тире, подчёркивание";
    const string KeyLocal = "LOCAL: {0} на {1}";
    const string KeyNameNote = "Имя станет именем файла ключа и подписью в authorized_keys на всех целях - по нему машину и отзывают.";
    const string KeyKnown = "УЖЕ ЗАВЕДЕНЫ: {0}";
    const string KeyNone = "Пока не заведено ни одной машины.";
    const string KeyFixHead = "Имя придётся записать иначе";
    const string KeyFixOk = "СОХРАНИТЬ";
    const string KeyTyped = "ВЫ ВВЕЛИ: {0}";
    const string KeyWillBe = "БУДЕТ: {0}";
    const string KeyFixNote = "Имя ляжет в имя файла ключа и в подпись на всех машинах, поэтому в нём только латиница в нижнем регистре, цифры, тире и подчёркивание.";
    // Transport
    const string TransportHead = "Сборка rclone.conf";
    const string TransportOk = "СОБРАТЬ";
    const string TransportAccount = "ИДЕНТИФИКАТОР УЧЁТНОЙ ЗАПИСИ CLOUDFLARE";
    const string TransportProfile = "ПРОФИЛЬ В r2.credentials";
    const string TransportNote = "Файл собирается из заготовки config\\rclone.sample.conf. Адреса машин, учётные записи и ключи окно берёт само - из targets.json и Tunnel\\SSH.";
    const string NoAddress = "адреса нет";
    const string TransportMachineKey = "КЛЮЧ МАШИН: {0}";
    const string TransportServerKey = "КЛЮЧ MAIN VPS: {0}";
    // R2
    const string R2Head = "R2 CREDS: ключи к R2 bucket";
    const string R2Ok = "ПОЛОЖИТЬ";
    const string R2File = "ФАЙЛ: ";
    const string R2Profile = "ПРОФИЛЬ: ";
    const string R2Now = "СЕЙЧАС: ";
    const string R2Exists = "файл есть, он будет переписан";
    const string R2Missing = "файла нет";
    const string R2Note = "Пара берётся в панели Cloudflare: R2 - Manage API tokens. Значения ложатся файлом, который читает rclone, и в журнал не попадают.";
    // Router
    const string RouterWhose = "Чей пароль вносим?";
    const string RouterHead = "Пароль учётной записи роутера";
    const string RouterOk = "СОХРАНИТЬ";
    const string RouterName = "РОУТЕР: ";
    const string RouterAccount = "УЧЁТНАЯ ЗАПИСЬ: admin";
    const string RouterNote = "Хранится переносимо в наборе, по имени роутера. Файл бесполезен без доступа к самому роутеру; в переписку и в репозиторий значение не попадает.";
    const string RouterSharedHead = "Пароль у роутеров общий?";
    const string RouterNext = "ДАЛЬШЕ";
    const string RouterSharedYes = "Да, у всех один";
    const string RouterSharedNote = "Сохранить и для {0}; выбор запомнится в DATA";
    const string RouterSharedNo = "Нет, у каждого свой";
    const string RouterSingleNote = "Остальным роутерам пароль внести отдельно; выбор запомнится в DATA";
    // RouterPick
    const string RouterWhich = "С каким роутером говорим?";
    // Beacon
    const string BeaconKey = "ключ: {0}";
    const string Yes = "есть";
    const string No = "нет";
    const string BeaconPort = "порт туннеля: {0}";
    const string BeaconAlive = "канал: держится через {0}";
    const string BeaconStarting = "канал: поднимается";
    const string BeaconRetrying = "канал: процесс пробует снова";
    const string BeaconDown = "канал: не поднят";
    const string BeaconNotMade = "канал: не заведён";
    const string BeaconMachine = "МАШИНА: {0}";
    const string BeaconWhat = "Машина сама держит одно исходящее соединение, а MAIN VPS или SECOND VPS открывает у себя порт на localhost: кто вошёл на него, через этот порт попадает сюда. Ни адаптера, ни службы, ни маршрутов.";
    const string BeaconWhen = "Нужен машине, до которой снаружи не дойти. Машине, которая ходит сама, он не нужен: лишний канал - это лишний ключ на MAIN VPS или SECOND VPS и лишний порт.";
    const string BeaconHead = "SSH TUN этой машины";
    const string BeaconNext = "ДАЛЬШЕ";
    const string BeaconFast = "ПОДНЯТЬ ЧЕРЕЗ SECOND VPS";
    const string BeaconFastNote = "Хост SECOND VPS: до него маршрут короче и идёт без VPN. Не ответит он - канал пойдёт через MAIN VPS.";
    const string BeaconPrivate = "ПОДНЯТЬ ЧЕРЕЗ MAIN VPS";
    const string BeaconPrivateNote = "Только MAIN VPS: маршрут длиннее, зато трафик не заходит на SECOND VPS. Для того, что нельзя показывать.";
    const string BeaconCheck = "ОСМОТРЕТЬ";
    const string BeaconCheckNote = "Ничего не менять: ключ, порт на MAIN VPS или SECOND VPS, процесс и слушает ли порт сейчас.";
    const string BeaconRemove = "УДАЛИТЬ";
    const string BeaconRemoveNote = "Остановить канал и удалить ключ туннеля с MAIN VPS или SECOND VPS. Ключ в данных остаётся.";
    const string BeaconFastTitle = "SSH TUN: ЧЕРЕЗ SECOND VPS";
    const string BeaconPrivateTitle = "SSH TUN: ЧЕРЕЗ MAIN VPS";
    const string BeaconCheckTitle = "SSH TUN: ОСМОТР";
    const string BeaconRemoveTitle = "SSH TUN: УДАЛЕНИЕ";
    // PublicKey
    const string PublicKeyHead = "Публичный ключ";
    const string PublicKeyOk = "СКОПИРОВАТЬ";
    const string PublicKeyNote = "Эту строку принимает та сторона: на Windows её кладёт setup-ssh-server.cmd, на MAIN VPS и SECOND VPS она дописывается в ~/.ssh/authorized_keys.";
}
