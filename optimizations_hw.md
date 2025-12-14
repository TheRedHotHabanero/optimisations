# Домашнее задание: «Комплексное исследование производительности чёрного ящика»

## Стартовый анализ
Попытка понять, что из себя представляет приложение, какие у него аргументы, сценарии использования возможные и тд.
```
chmod +x app_linux_amd64
file ./app_linux_amd64
```
получили вывод:
```
./app_linux_amd64: ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, BuildID[sha1]=bbffb0ad6a306189dc3b471a20072e275635990d, with debug_info, not stripped
```
далее 
```
ldd ./app_linux_amd64
```
получили вывод:
```
не является динамическим исполняемым файлом
```
далее
```
strings ./app_linux_amd64 | head
```
но тут ничего полезного:
```
43s9gtIb2nzoz-btSD73/BiQ9Vk7r7Cgvi0Xdj82Z/EnfuaA3zd4WEqx0qjnes/tpilcBJpMYGn2pVCKCBW
.'V5
v,UH
|$XL
T$xH
T$`L
L$hE
t$OL
d$pH
L$pf
```
далее идет попытка запуска с `--help`:
```
./app_linx_amd64 --help || ./app_linux_amd64 -h || ./app_linux_amd64
```
но на выходе имеем только запуск, никакого хелпа нет. Из всех опробованных команд что-то выдала интересное только strings. Попробуем поискать там более конкретные вещи. Уже при попытке запуска было выведено на экран:
`mystery_app: starting HTTP server on :8080`, значит попробуем пойти в эту сторону:
```
strings ./app_linux_amd64 | grep -i -E 'http|GET /|POST /|port|listen' | head -n 30
```
и получили следующий вывод:
```
:httpt
:httpuYA
>httpu
>http
8httpf
8httpu!
9httpu
HTTP/1.0H9
HTTP/1.1H9
HTTP/2.0M9
http/1.0H92t
http/1.1H92u
HTTP/2.0H9
Port
port
HTTP1
HTTP2
Listen
Export
*http.I
Listener
net/http
AddrPort
SetHTTP1
SetHTTP2
Exporter
        ServeHTTP
        listeners
        HTTPProxy
        httpProxy
```
попробуем еще поискать сценарии использования таким образом:
```
strings ./app_linux_amd64 | grep -i -E 'usage|help|option|error|fail|version' | head -n 30
```
и получили следующий вывод:
```
 error: H
optionalH9
optionalH
optionalH
optionalH
optionalH
optionalH
optionalH
Error
error
*error
errors 
version
Version
erroring
ErrorLog
*[]error
eofError
KeyUsage
SetError
optional
        connError
*net.Error
countError
CountError
FlushError
MinVersion
MaxVersion
*url.Error
*chan error
```
попробуем еще взять более длинные строки:
```
strings -n 8 ./app_linux_amd64 | head -n 40
```
и видим следующее:
```
43s9gtIb2nzoz-btSD73/BiQ9Vk7r7Cgvi0Xdj82Z/EnfuaA3zd4WEqx0qjnes/tpilcBJpMYGn2pVCKCBW
l$ M9,$u
UUUUUUUUH!
33333333H!
/proc/seH
roc/selfH
/proc/seH
/self/moH
\$PH9H@v#H
l$8M9,$u
P H9S uqH
S0H9P0ug
P98S9uUH
v&H9L$ r
debugCal
debugCal
debugCalH9
debugCalH9
debugCalH9
runtime.
runtime H
 error: H
/dev/nulH
L$HI9Qhu
P`f9P2tgH
\$0f9C2u
UUUUUUUUH!
UUUUUUUUH
wwwwwwwwH!
wwwwwwwwH
J0f9J2vmH
runtime.H9
L9L$Xt$H
runtime.H9
reflect.H9
GODEBUG=H9
GODEBUG=1
H92t9H9rHt3H
memprofiL9
9q0s&H9J
```
штуки вроде `GODEBUG=H9` и `GODEBUG=1` говорят нам о том, что приложение скорее всего написано на Go, и оно серверное, так что тут какой-то http сервер на Go. 
Попробовав еще дополнительно `strings ./app_linux_amd64 | grep -E '/[a-zA-Z0-9_-]+' | head -n 40` какой-то приниципиально новой информации не было получено, но видно, что идет какая-то нагрущка, тк приложение пытается узнать лимиты, и что-то льет в /dev/null
```
43s9gtIb2nzoz-btSD73/BiQ9Vk7r7Cgvi0Xdj82Z/EnfuaA3zd4WEqx0qjnes/tpilcBJpMYGn2pVCKCBW
/proc/seH
roc/selfH
/cgroup
/proc/seH
/self/moH
t$/L
|$/H
=i/W
D$/D
D$/D
D$/D
L$/H
L$/f
\$/H
/dev/nulH
D$/H
D$/E1
D$/I
=7/U
w/9H
T$/L
=W/T
}/H9
T$/I9
=/xQ
/s7H
v/UH
t/E1
L$/H
L$/H
gopau/f
\$/H
/s"H
L$/H
D$/D
L$/H
D$/D
|$/D
w/Hc
```
кстати тут снова встречаем какие-то намеки на Go `gopau/f`. Предварительно достаточно узнали. Теперь надо осмотреть мою текущую систему: сохранено в файле рядом `system_report.txt`, чтобы не так грузить этот отчет. Перехожу к самому заданию:
