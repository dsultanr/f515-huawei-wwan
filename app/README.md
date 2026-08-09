# F515 WWAN — приложение

Кнопки над `scripts/wwan-up.sh`: **Check** / **Bring up** / **+ Apps** / **Down** /
**Status** / **Log**. Ничего не выполняется само — ни на `BOOT_COMPLETED`, ни при открытии
приложения, только по нажатию.

Пакет `su.dsr.f515wwan`, независимый от `netkeeper`/`modemguide` этого стенда — можно
ставить/не ставить/удалять отдельно.

## Как это работает

adbd на этой прошивке уже слушает `127.0.0.1:5555` и работает от root без дополнительного
`su`. `AdbClient.java` — минимальный ADB-клиент (CNXN → AUTH RSA/SHA1 → OPEN `shell:`),
коннектится на loopback и сразу получает root-шелл.

При первом запуске приложение заливает `scripts/*.sh`, оба `.ko` и `huawei-modeswitch` в
`/data/local/tmp/wwan/` (сверяя размер файла на устройстве — уже залитые файлы повторно
не передаются) и дальше просто вызывает `wwan-up.sh` с нужными аргументами. Вся логика
подъёма/проверок — в самом скрипте, приложение её не дублирует.

### Ключ adb

**`assets/adbkey`/`adbkey.pub` в этом репозитории — одноразовая заглушка**, сгенерированная
для публикации. adbd на этой прошивке принимает любой ключ (`/data/misc/adb/adb_keys`
пуст), так что заглушка работает и на реальном устройстве — но если ставишь на голову,
которая ключи всё-таки проверяет, сгенерируй свой:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -pkeyopt rsa_keygen_pubexp:65537 -out assets/adbkey
python3 mkadbpub.py assets/adbkey "you@host" > assets/adbkey.pub
```

**Никогда не коммить сюда свой реальный `~/.android/adbkey`** — это приватный ключ.

## Файлы

| Путь | Что |
|---|---|
| `assets/wwan-up.sh`, `dial.sh`, `at.sh` | копии `scripts/*` — держи их синхронизированными |
| `assets/*.ko`, `assets/huawei-modeswitch` | копии `modules/prebuilt/*` и `tools/huawei-modeswitch` |
| `assets/adbkey`, `assets/adbkey.pub` | ключ хоста для self-adb (см. выше) |
| `src/su/dsr/f515wwan/AdbClient.java` | минимальный ADB-клиент |
| `src/su/dsr/f515wwan/Keeper.java` | заливка файлов, запуск стадий, чтение статуса/лога |
| `src/su/dsr/f515wwan/MainActivity.java` | экран с кнопками |

## Сборка

```bash
./build.sh          # -> F515WwanApp.apk
```

`aapt2 → javac → d8 → zipalign → apksigner`, без gradle. Нужен Android SDK
(`aapt2`/`d8`/`zipalign`/`apksigner`, платформа `android-11`+) и JDK. `keystore.jks`
создаётся автоматически при первой сборке.

## Установка

На этой прошивке `pm install`/`adb install` отключены политикой производственной сборки
(`ro.build.type=user`). APK нужно ставить так же, как остальные приложения этого стенда:
через USB-флешку вручную или инъекцией в EngMode. Само по себе приложение решение об
установке не принимает — собранный `F515WwanApp.apk` просто лежит рядом.
