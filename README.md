# SarmatDTC — генератор DTC для серверов SARMAT (DCS World)

При подключении к серверу, в названии которого есть **SARMAT**, мод берёт обстановку с
[живой карты](https://baikalprimestudio.com/map.html) и при выборе слота создаёт картриджи DTC
для вашей коалиции:

| Модуль | Что размечается |
|---|---|
| AH-64D | Control Measures: свои и вражеские группы, свои ПВО, FARP-ы. Targets/Threats: вражеские ПВО с типом. Линия фронта (FLOT) |
| F-16C | Линия фронта (GEO LINES) |
| F/A-18C | Линия фронта (SA → FLOT) |
| F-14BU | Линия фронта (план навигации 1) |

Файлы `Saved Games\DCS.openbeta\DTC\SARMAT_<модуль>.dtc` перезаписываются при каждом выборе слота.
Загрузите их в окне DTC перед вылетом. Остальные настройки картриджа (радио, CMDS и т.д.) остаются по умолчанию.

## Установка

Скопируйте папку `Scripts` из репозитория в `%USERPROFILE%\Saved Games\DCS.openbeta\`.
Нужны Windows 10/11: используется встроенный `curl.exe`.

Настройки — блок `CONFIG` в начале `Scripts/SarmatDTC/SarmatDTC.lua`.

## Тесты

```powershell
powershell -ExecutionPolicy Bypass -File "Scripts\SarmatDTC\tests\run_tests.ps1"
```

Подробности для разработчиков и агентов — в [AGENTS.md](AGENTS.md).
