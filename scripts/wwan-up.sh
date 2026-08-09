#!/system/bin/sh
# wwan-up.sh — подъём Huawei-модема как WWAN на голове F515.
#
# Скрипт идёт стадиями и каждую сначала ПРОВЕРЯЕТ: уже сделано — пропускает,
# не хватает предусловия — останавливается с понятным сообщением и подсказкой,
# а не падает где-то в середине. Повторный запуск безопасен.
#
#   wwan-up.sh              подъём (стадии 1..10)
#   wwan-up.sh --check      только диагностика, ничего не меняет
#   wwan-up.sh --system     дополнительно отдать интернет приложениям Android
#   wwan-up.sh --down       остановить pppd (маршруты не трогает)
#
# Настройки: переменные окружения или /data/local/tmp/wwan.conf (см. wwan.conf.example).

DIR=$(cd "$(dirname "$0")" && pwd)
TMP=/data/local/tmp
LOG=${WWAN_LOG:-$TMP/wwan.log}
PPP_LOG=$TMP/ppp.log
CONF=${WWAN_CONF:-$TMP/wwan.conf}

[ -f "$CONF" ] && . "$CONF"

APN=${WWAN_APN:-internet}
PPP_USER=${WWAN_USER:-}
PPP_PASS=${WWAN_PASS:-}
DIAL=${WWAN_DIAL:-*99#}
# Куда класть маршрут модема. 99 = «legacy_system» в терминах Android; таблица
# служебная, основной main при этом не трогается и управляющий adb не рвётся.
TABLE=${WWAN_TABLE:-99}

CHECK_ONLY=0
DO_SYSTEM=0
DO_DOWN=0
for a in "$@"; do
	case "$a" in
	-c | --check)  CHECK_ONLY=1 ;;
	-s | --system) DO_SYSTEM=1 ;;
	--down)        DO_DOWN=1 ;;
	-h | --help)   sed -n '2,20p' "$0"; exit 0 ;;
	*) echo "неизвестный аргумент: $a (см. --help)"; exit 64 ;;
	esac
done

# ---------------------------------------------------------------- вывод/логи --
FAILED=0

say()   { echo "$*"; echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null; }
stage() { STAGE="$1"; say ""; say "== $1"; }
ok()    { say "   [ ok ] $*"; }
skip()  { say "   [ -- ] $*"; }
warn()  { say "   [warn] $*"; }
# die <что не так> <что делать>
die() {
	say "   [FAIL] $1"
	[ -n "$2" ] && say "          -> $2"
	FAILED=1
	exit 1
}

# Действие, которое в режиме --check только печатается.
do_it() {
	if [ "$CHECK_ONLY" = 1 ]; then
		say "   [dry ] $*"
		return 0
	fi
	"$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ хелперы --
# Каталог модема в sysfs + его VID/PID.
find_usb_dev() {
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		v=$(cat "$d/idVendor" 2>/dev/null)
		[ "$v" = "12d1" ] || continue
		USB_DEV=$d
		USB_VID=$v
		USB_PID=$(cat "$d/idProduct" 2>/dev/null)
		return 0
	done
	return 1
}

# ttyUSB, соответствующий интерфейсу с заданным bInterfaceProtocol
# (10 = modem/PPP-порт, 12 = PCUI/AT-порт).
port_for_proto() {
	for i in "$USB_DEV":*; do
		[ -f "$i/bInterfaceProtocol" ] || continue
		[ "$(cat "$i/bInterfaceProtocol" 2>/dev/null)" = "$1" ] || continue
		for t in "$i"/ttyUSB*; do
			[ -e "$t" ] || continue
			echo "/dev/$(basename "$t")"
			return 0
		done
	done
	return 1
}

ko_vermagic() { grep -ao 'vermagic=[^[:space:]]*' "$1" 2>/dev/null | head -1 | cut -d= -f2; }

# Загрузка модуля с переводом ошибок insmod на человеческий.
load_module() {
	_ko=$1
	_name=$2
	_probe=$3 # путь в sysfs/procfs, по которому видно, что модуль уже работает

	if [ -n "$_probe" ] && [ -e "$_probe" ]; then
		skip "$_name: уже загружен ($_probe на месте)"
		return 0
	fi
	if lsmod 2>/dev/null | grep -q "^$_name "; then
		skip "$_name: уже в lsmod"
		return 0
	fi
	[ -f "$_ko" ] || die "$_name: нет файла $_ko" \
		"положи .ko рядом со скриптом или укажи WWAN_MODDIR"

	# Главная проверка перед insmod: vermagic. Несовпадение = гарантированная
	# порча памяти ядра вплоть до паники, поэтому дальше не идём.
	_vm=$(ko_vermagic "$_ko")
	_kr=$(uname -r)
	if [ -z "$_vm" ]; then
		warn "$_name: в модуле нет vermagic — проверить не получилось"
	elif [ "$_vm" != "$_kr" ]; then
		die "$_name: модуль собран для ядра '$_vm', а на голове '$_kr'" \
			"пересобрать модули под это ядро (modules/build-cfi.sh)"
	else
		ok "$_name: vermagic совпадает ($_vm)"
	fi
	if [ "$(grep -ac '__cfi_check' "$_ko" 2>/dev/null)" = "0" ]; then
		die "$_name: в модуле нет __cfi_check" \
			"ядро собрано с CONFIG_CFI_CLANG и не-CFI модули не принимает — собирать modules/build-cfi.sh"
	fi

	if [ "$CHECK_ONLY" = 1 ]; then
		say "   [dry ] insmod $_ko"
		return 0
	fi

	_err=$(insmod "$_ko" 2>&1)
	_rc=$?
	if [ $_rc -eq 0 ]; then
		ok "$_name: загружен"
		return 0
	fi
	case "$_err" in
	*"File exists"* | *"уже существует"*)
		skip "$_name: уже загружен"
		return 0 ;;
	*"Invalid module format"* | *"invalid module format"*)
		die "$_name: ядро отвергло формат модуля ($_err)" \
			"почти всегда это несовпадение vermagic/раскладки struct module — пересобрать" ;;
	*"Unknown symbol"*)
		die "$_name: не хватает символов ядра ($_err)" \
			"смотри dmesg: ядро печатает, какого именно символа нет" ;;
	*"Operation not permitted"*)
		die "$_name: insmod запрещён ($_err)" \
			"проверь, что шелл root и SELinux не Enforcing" ;;
	*)
		die "$_name: insmod не сработал ($_err)" "смотри dmesg" ;;
	esac
}

# Одна AT-команда, ответ на stdout. Порт переводим в raw без эха, иначе ответы
# перемешиваются с эхом и распарсить их нельзя. Скорость не трогаем: у USB-модема
# она виртуальная, а toybox stty на этом драйвере её выставить не может и тогда
# отбрасывает всю команду целиком. -iuclc обязателен — иначе порт отдаёт ответы
# в нижнем регистре ("ok" вместо "OK").
at() {
	_tty=$1
	_cmd=$2
	_wait=${3:-2}
	[ -c "$_tty" ] || return 1
	stty -F "$_tty" raw -echo -iuclc min 0 time 5 >/dev/null 2>&1
	exec 9<>"$_tty" || return 1
	timeout 1 cat <&9 >/dev/null 2>&1
	printf '%s\r' "$_cmd" >&9
	_out=$(timeout "$_wait" cat <&9 | tr -d '\r')
	exec 9<&-
	printf '%s' "$_out"
}

ppp_addr() { ip -4 -o addr show ppp0 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }

# Отвечает ли DNS-сервер. На голове нет ни nslookup, ни dig — есть только
# busybox (и то не всегда), поэтому «проверить не смогли» и «не отвечает» надо
# различать: молча считать сервер мёртвым и переписывать netfilter нельзя.
dns_answers() {
	if have nslookup; then
		timeout 5 nslookup connectivitycheck.gstatic.com "$1" >/dev/null 2>&1
	elif have busybox; then
		timeout 5 busybox nslookup connectivitycheck.gstatic.com "$1" >/dev/null 2>&1
	else
		warn "нечем проверить DNS $1 (нет nslookup/busybox) — считаю, что не отвечает"
		return 1
	fi
}

# ------------------------------------------------------------------- --down --
if [ "$DO_DOWN" = 1 ]; then
	stage "остановка"
	_pids=$(pidof pppd 2>/dev/null)
	if [ -n "$_pids" ]; then
		kill $_pids && ok "pppd остановлен (pid $_pids)"
	else
		skip "pppd не запущен"
	fi
	say ""
	say "Маршруты и правила скрипт НЕ удаляет. Если нужно убрать вручную:"
	say "   ip route del default dev ppp0 table $TABLE"
	say "   ip rule del oif ppp0 table $TABLE"
	exit 0
fi

say "=================================================================="
say "wwan-up $(date '+%F %T')  APN=$APN  check=$CHECK_ONLY  system=$DO_SYSTEM"

# --------------------------------------------------------- 1. окружение -----
stage "1/10 окружение"

[ "$(id -u)" = "0" ] || die "нужен root (сейчас uid=$(id -u))" \
	"adbd на этой прошивке уже root: adb shell должен давать uid=0"
ok "root"

KREL=$(uname -r)
ok "ядро $KREL"

if have getenforce; then
	_se=$(getenforce 2>/dev/null)
	case "$_se" in
	Enforcing) warn "SELinux Enforcing — insmod может быть запрещён" ;;
	*)         ok "SELinux $_se" ;;
	esac
fi

_missing=""
for t in ip insmod lsmod pppd stty timeout; do
	have "$t" || _missing="$_missing $t"
done
[ -z "$_missing" ] || die "в системе нет:$_missing" \
	"без них подъём невозможен; pppd обычно /system/bin/pppd"
ok "утилиты на месте (ip, insmod, pppd, stty, timeout)"

# --------------------------------------------------------- 2. файлы ---------
stage "2/10 файлы"

MODDIR=${WWAN_MODDIR:-$DIR}
[ -f "$MODDIR/usbserialmerged2.ko" ] || MODDIR=$TMP
KO_USB=$MODDIR/usbserialmerged2.ko
KO_PPP=$MODDIR/ppp_async.ko
MODESWITCH=${WWAN_MODESWITCH:-$MODDIR/huawei-modeswitch}
DIAL_SH=${WWAN_DIALSH:-$DIR/dial.sh}
[ -f "$DIAL_SH" ] || DIAL_SH=$TMP/dial.sh

for f in "$KO_USB" "$KO_PPP" "$DIAL_SH"; do
	[ -f "$f" ] || die "нет файла $f" "разложи содержимое scripts/ и modules/prebuilt/ в $TMP"
done
[ -x "$DIAL_SH" ] || chmod 755 "$DIAL_SH" 2>/dev/null
ok "модули и dial.sh найдены в $MODDIR"
[ -f "$MODESWITCH" ] || warn "нет $MODESWITCH — если модем окажется в storage-режиме, переключить будет нечем"

# --------------------------------------------------------- 3. USB ----------
stage "3/10 USB-устройство"

if ! find_usb_dev; then
	say "   видимые USB-устройства:"
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		say "      $(basename "$d")  $(cat "$d/idVendor"):$(cat "$d/idProduct")"
	done
	die "модем Huawei (12d1:*) не найден" \
		"проверь кабель и питание USB-порта; после перевтыкания модем возвращается в storage-режим"
fi
ok "найден $USB_VID:$USB_PID ($(basename "$USB_DEV"))"

NEED_SWITCH=0
case "$USB_PID" in
1506 | 1465 | 140c | 1c05 | 14ac) ok "режим с AT/PPP-портами" ;;
14fe | 1f01 | 1f02 | 1446 | 14ad | 1c0b)
	NEED_SWITCH=1
	warn "модем в storage-режиме — нужен modeswitch" ;;
*)
	warn "PID $USB_PID незнакомый — пробуем как есть" ;;
esac

# --------------------------------------------------------- 4. modeswitch ---
stage "4/10 modeswitch"

if [ "$NEED_SWITCH" = 0 ]; then
	skip "не требуется"
else
	[ -f "$MODESWITCH" ] || die "нужен modeswitch, но $MODESWITCH отсутствует" \
		"собрать tools/build-tools.sh и положить бинарь рядом"
	[ -x "$MODESWITCH" ] || chmod 755 "$MODESWITCH"
	if [ "$CHECK_ONLY" = 1 ]; then
		say "   [dry ] $MODESWITCH"
	else
		"$MODESWITCH" 2>&1 | while read -r l; do say "   $l"; done
		# Модем переподключается с новым PID — ждём появления.
		i=0
		while [ $i -lt 20 ]; do
			sleep 1
			if find_usb_dev && [ "$USB_PID" != "14fe" ]; then break; fi
			i=$((i + 1))
		done
		find_usb_dev || die "после modeswitch модем пропал с шины" \
			"вытащить и вставить модем, затем запустить скрипт заново"
		case "$USB_PID" in
		14fe | 1f01 | 1f02 | 1446 | 14ad | 1c0b)
			die "modeswitch не сработал, PID остался $USB_PID" \
				"проверь, что ядро не держит usb-storage, и попробуй ещё раз" ;;
		esac
		ok "переключён в $USB_VID:$USB_PID"
	fi
fi

# --------------------------------------------------------- 5. модули -------
stage "5/10 модуль usbserial+option"

# rmmod на этой голове роняет ядро — выгружать модули нельзя ни при каких условиях.
load_module "$KO_USB" usbserialmerged2 /sys/bus/usb/drivers/option

# --------------------------------------------------------- 6. порты --------
stage "6/10 последовательные порты"

if [ "$CHECK_ONLY" = 1 ] && [ ! -e /sys/bus/usb/drivers/option ]; then
	skip "модуль не загружен (--check), порты проверить нечем"
else
	i=0
	while [ $i -lt 15 ]; do
		[ -c /dev/ttyUSB0 ] && break
		sleep 1
		i=$((i + 1))
	done

	if [ ! -c /dev/ttyUSB0 ]; then
		# Драйвер есть, но интерфейсы не подхватились — чаще всего PID не в
		# таблице option. Это лечится штатным механизмом new_id.
		warn "ttyUSB не появились, пробуем добавить $USB_VID:$USB_PID через new_id"
		for p in /sys/bus/usb-serial/drivers/option1/new_id /sys/bus/usb/drivers/option/new_id; do
			[ -w "$p" ] && do_it sh -c "echo '$USB_VID $USB_PID' > $p"
		done
		sleep 2
	fi
	[ -c /dev/ttyUSB0 ] || die "порты ttyUSB не появились" \
		"смотри dmesg: привязался ли option к интерфейсам $(basename "$USB_DEV"):1.*"

	MODEM_TTY=$(port_for_proto 10) || MODEM_TTY=/dev/ttyUSB0
	CTRL_TTY=$(port_for_proto 12)  || CTRL_TTY=/dev/ttyUSB1
	[ -c "$CTRL_TTY" ] || CTRL_TTY=$MODEM_TTY
	ok "модемный порт $MODEM_TTY, управляющий $CTRL_TTY"
	ok "привязано интерфейсов: $(ls -d "$USB_DEV":*/ttyUSB* 2>/dev/null | wc -l)"
fi

# --------------------------------------------------------- 7. PPP в ядре ---
stage "7/10 PPP в ядре"

[ -c /dev/ppp ] || die "нет /dev/ppp — в ядре не собран CONFIG_PPP" \
	"это уже не лечится модулем, нужен другой способ (NCM/NDIS)"
ok "/dev/ppp на месте"

if grep -q '^ppp' /proc/tty/ldiscs 2>/dev/null; then
	skip "line discipline ppp уже зарегистрирована"
else
	load_module "$KO_PPP" ppp_async ""
	[ "$CHECK_ONLY" = 1 ] || grep -q '^ppp' /proc/tty/ldiscs 2>/dev/null ||
		die "ppp_async загрузился, но ldisc ppp не появилась" "смотри dmesg"
	[ "$CHECK_ONLY" = 1 ] || ok "line discipline ppp зарегистрирована"
fi

# --------------------------------------------------------- 8. SIM/сеть -----
stage "8/10 SIM и регистрация в сети"

if pidof pppd >/dev/null 2>&1; then
	skip "pppd уже держит порт — AT-опрос пропускаем"
elif [ "$CHECK_ONLY" = 1 ] && [ ! -c "${CTRL_TTY:-/dev/null}" ]; then
	skip "нет управляющего порта"
else
	at "$CTRL_TTY" "ATE0" 1 >/dev/null 2>&1
	# Регистр ответов приводим к верхнему: на части портов включён iuclc и
	# модем отвечает "ok" вместо "OK".
	_r=$(at "$CTRL_TTY" "AT" 2 | tr 'a-z' 'A-Z')
	case "$_r" in
	*OK*) ok "порт $CTRL_TTY отвечает" ;;
	*)    die "порт $CTRL_TTY не отвечает на AT" \
		    "порт мог занять другой процесс; проверь другой ttyUSB" ;;
	esac

	_r=$(at "$CTRL_TTY" "AT+CPIN?" 3 | tr 'a-z' 'A-Z')
	case "$_r" in
	*READY*)      ok "SIM готова" ;;
	*"SIM PIN"*)  die "SIM требует PIN" "сними PIN на телефоне или задай его вручную: AT+CPIN=\"1234\"" ;;
	*"SIM PUK"*)  die "SIM заблокирована (PUK)" "разблокируй SIM на телефоне" ;;
	*ERROR*)      die "модем не видит SIM" "проверь, что SIM вставлена и контакты чистые" ;;
	*)            warn "непонятный ответ на AT+CPIN?: $(echo "$_r" | tr '\n' ' ')" ;;
	esac

	# Сигнал и регистрация появляются не мгновенно после включения модема.
	i=0
	REG=""
	while [ $i -lt 30 ]; do
		_r=$(at "$CTRL_TTY" "AT+CREG?" 2)$(at "$CTRL_TTY" "AT+CGREG?" 2)
		case "$_r" in
		*",1"* | *",5"*) REG=1; break ;;
		esac
		sleep 2
		i=$((i + 2))
	done
	if [ -n "$REG" ]; then
		ok "зарегистрирован в сети"
	else
		die "модем не регистрируется в сети (30 с ожидания)" \
			"проверь баланс/активность SIM и уровень сигнала, вынеси антенну"
	fi

	_r=$(at "$CTRL_TTY" "AT+CSQ" 2)
	_csq=$(echo "$_r" | sed -n 's/.*+CSQ: \([0-9]*\),.*/\1/p' | head -1)
	case "$_csq" in
	99 | "") warn "уровень сигнала неизвестен (+CSQ: $_csq)" ;;
	*)
		if [ "$_csq" -lt 8 ] 2>/dev/null; then
			warn "слабый сигнал (+CSQ: $_csq, меньше 8) — связь может рваться"
		else
			ok "сигнал +CSQ: $_csq"
		fi ;;
	esac

	_r=$(at "$CTRL_TTY" "AT+COPS?" 3)
	_op=$(echo "$_r" | sed -n 's/.*+COPS: [0-9]*,[0-9]*,"\([^"]*\)".*/\1/p' | head -1)
	[ -n "$_op" ] && ok "оператор: $_op"
fi

# --------------------------------------------------------- 9. дозвон -------
stage "9/10 дозвон"

ADDR=$(ppp_addr)
if [ -n "$ADDR" ]; then
	skip "ppp0 уже поднят: $ADDR"
elif [ "$CHECK_ONLY" = 1 ]; then
	say "   [dry ] pppd $MODEM_TTY ... connect $DIAL_SH"
else
	if pidof pppd >/dev/null 2>&1; then
		warn "pppd уже запущен, но ppp0 без адреса — ждём"
	else
		# nodefaultroute — принципиально: подмена основного маршрута оборвала бы
		# управляющий adb. Маршрутизацией занимается стадия 10.
		_auth=""
		[ -n "$PPP_USER" ] && _auth="user $PPP_USER"
		APN="$APN" WWAN_DIAL="$DIAL" setsid pppd "$MODEM_TTY" 115200 \
			nodetach noauth nodefaultroute noipdefault \
			ipcp-accept-local ipcp-accept-remote novj novjccomp local \
			lcp-echo-interval 30 lcp-echo-failure 4 \
			$_auth logfile "$PPP_LOG" connect "$DIAL_SH" \
			</dev/null >/dev/null 2>&1 &
		say "   pppd запущен на $MODEM_TTY (APN $APN)"
	fi

	i=0
	while [ $i -lt 45 ]; do
		ADDR=$(ppp_addr)
		[ -n "$ADDR" ] && break
		pidof pppd >/dev/null 2>&1 || break
		sleep 1
		i=$((i + 1))
	done

	if [ -z "$ADDR" ]; then
		say "   последние строки $PPP_LOG:"
		tail -n 12 "$PPP_LOG" 2>/dev/null | tr -d '\r' | while read -r l; do say "      $l"; done
		_t=$(tail -n 40 "$PPP_LOG" 2>/dev/null)
		case "$_t" in
		*"status = 0x2"*)
			die "модем отверг APN" "проверь APN оператора: сейчас '$APN' (WWAN_APN=...)" ;;
		*"status = 0x3"* | *"NO CARRIER"*)
			die "нет ответа CONNECT на дозвон" "модем не зарегистрирован либо номер дозвона не '$DIAL'" ;;
		*"timeout sending"*)
			die "нет ответа по LCP" "скорее всего это не модемный порт; попробуй WWAN_TTY=/dev/ttyUSB2" ;;
		*"authentication failed"* | *"Peer refused"* | *"CHAP authentication failed"*)
			die "оператор требует логин/пароль" "задай WWAN_USER и WWAN_PASS" ;;
		*)
			die "ppp0 не поднялся за 45 с" "разбирайся по $PPP_LOG" ;;
		esac
	fi
	ok "ppp0 поднят: $ADDR"
fi

# --------------------------------------------------------- 10. маршруты ----
stage "10/10 маршруты и проверка связи"

if [ -z "$ADDR" ] && [ "$CHECK_ONLY" = 1 ]; then
	skip "ppp0 не поднят"
else
	do_it ip route replace default dev ppp0 table "$TABLE"
	ip rule show 2>/dev/null | grep -q "from $ADDR " || do_it ip rule add from "$ADDR" table "$TABLE"
	ip rule show 2>/dev/null | grep -q "oif ppp0 "    || do_it ip rule add oif ppp0 table "$TABLE"
	ok "маршрут по умолчанию для ppp0 в таблице $TABLE"

	if [ "$CHECK_ONLY" = 0 ]; then
		if ping -c 2 -W 4 -I ppp0 8.8.8.8 >/dev/null 2>&1; then
			ok "связь есть (ping 8.8.8.8 через ppp0)"
		else
			warn "ppp0 поднят, но ping 8.8.8.8 не проходит"
			warn "у оператора может быть заблокирован ICMP — проверь curl/nslookup"
		fi
	fi
fi

# ------------------------------------------------- опционально: приложения --
if [ "$DO_SYSTEM" = 1 ]; then
	stage "+ интернет для приложений Android"

	# Правила вендора 9990-9999 «from all lookup main» идут раньше fwmark-правил,
	# поэтому root/adb-сессии достаточно default в main.
	_cur=$(ip route show table main 2>/dev/null | grep '^default')
	if [ -n "$_cur" ]; then
		warn "в main уже есть default: $_cur"
		warn "не трогаю — убери его вручную, если нужен модем"
	else
		do_it ip route replace default dev ppp0 table main metric 20
		ok "default dev ppp0 добавлен в main (metric 20)"
	fi

	# У приложений маршрутизация другая: ConnectivityService помечает их сокеты
	# fwmark'ом конкретной сети (netd, per-app default network) и заворачивает
	# в СВОЮ таблицу маршрутизации ("vlan72" для этой сети) — правило main здесь
	# вообще не участвует. Штатный TBOX физически снят, но Android держит его
	# "призрачную" сотовую сеть (единственную с CELLULAR/INTERNET, когда Wi-Fi
	# выключен), и таблица vlan72 указывает default на мёртвый шлюз
	# 192.168.72.1 (постоянная ARP-запись без реального устройства за ней) —
	# трафик приложений туда просто проваливается. Проверено напрямую:
	# `ping -m <fwmark-этой-сети> 8.8.8.8` не проходил до этой правки и проходит
	# после переопределения default в таблице vlan72 на ppp0.
	_line=$(dumpsys connectivity 2>/dev/null | grep -m1 'type: Tbox')
	TB_IF=$(echo "$_line" | sed -n 's/.*InterfaceName: \([a-z0-9._-]*\).*/\1/p')
	TB_DNS=$(echo "$_line" | sed -n 's/.*DnsAddresses: \[ *\/\([0-9.]*\).*/\1/p')
	TB_IF=${TB_IF:-vlan72}
	TB_DNS=${TB_DNS:-192.168.72.1}
	TB_SRC=$(ip -o -4 addr show "$TB_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

	if [ -z "$TB_SRC" ]; then
		warn "у $TB_IF нет адреса — эта сеть сейчас не активна, пропускаю"
	elif ip route show table "$TB_IF" 2>/dev/null | grep -q "^default dev ppp0"; then
		skip "таблица $TB_IF уже указывает на ppp0"
	else
		do_it ip route replace default dev ppp0 table "$TB_IF" metric 5
		ok "таблица $TB_IF: default переключён на ppp0 (приложения теперь маршрутизируются через модем)"
	fi

	# DNS оператора берём у самого модема, 8.8.8.8 — запасной вариант. Нужен
	# отдельно от правки таблицы выше: сам DNS-сервер 192.168.72.1 лежит внутри
	# подсети vlan72/24, для него action маршрута per-host (scope link) важнее
	# default и всегда будет уводить пакет в мёртвый L2 — что бы мы ни клали в
	# default той же таблицы. Поэтому адрес сервера подменяем DNAT'ом на живой,
	# после чего пакет уже выходит из подсети и идёт по (уже исправленному) default.
	DNS=""
	if [ -n "$CTRL_TTY" ] && [ -c "$CTRL_TTY" ]; then
		DNS=$(at "$CTRL_TTY" "AT+CGCONTRDP=1" 3 |
			sed -n 's/.*+CGCONTRDP: [^"]*"[^"]*","[^"]*","[^"]*","\([0-9.]*\)".*/\1/p' | head -1)
	fi
	DNS=${DNS:-8.8.8.8}

	if [ -z "$TB_SRC" ]; then
		: # уже предупредили выше
	elif dns_answers "$TB_DNS"; then
		skip "DNS $TB_DNS уже отвечает — netfilter не трогаю"
	else
		for proto in udp tcp; do
			iptables -w 10 -t nat -C OUTPUT -d "$TB_DNS" -p $proto --dport 53 \
				-j DNAT --to-destination "$DNS:53" 2>/dev/null ||
				do_it iptables -w 10 -t nat -A OUTPUT -d "$TB_DNS" -p $proto --dport 53 \
					-j DNAT --to-destination "$DNS:53"
		done
		iptables -w 10 -t nat -C POSTROUTING -s "$TB_SRC" -o ppp0 -j MASQUERADE 2>/dev/null ||
			do_it iptables -w 10 -t nat -A POSTROUTING -s "$TB_SRC" -o ppp0 -j MASQUERADE
		ok "DNS $TB_DNS ($TB_IF) перенаправлен на $DNS через ppp0"
	fi

	# Признак, который реально видят приложения (не заглядывая внутрь netd):
	# ConnectivityService периодически (не мгновенно) перепроверяет валидацию —
	# сразу после этой стадии сеть ещё может числиться невалидированной.
	if [ "$CHECK_ONLY" = 0 ]; then
		_val=$(dumpsys connectivity 2>/dev/null | grep -m1 'type: Tbox' | grep -o 'everValidated{[a-z]*}')
		case "$_val" in
		*true*) ok "сеть приложений (Tbox) уже провалидирована" ;;
		*) warn "сеть приложений (Tbox) ещё не провалидирована — Android перепроверяет её не сразу, подожди и посмотри снова: dumpsys connectivity | grep -A1 'type: Tbox'" ;;
		esac
	fi
fi

# ------------------------------------------------------------------ итог ----
say ""
say "== итог"
say "   ppp0:      ${ADDR:-не поднят}"
say "   маршрут:   $(ip route show table "$TABLE" 2>/dev/null | head -1)"
if [ "$CHECK_ONLY" = 0 ] && [ -n "$ADDR" ]; then
	if timeout 10 ping -c 1 -W 5 -I ppp0 8.8.8.8 >/dev/null 2>&1; then
		say "   интернет:  есть"
	else
		say "   интернет:  ping не проходит (см. предупреждения выше)"
	fi
fi
say "   лог:       $LOG"
exit 0
