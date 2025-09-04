#!/bin/sh

# AksTis Router Temp Monitor

# Мониторинг температуры процессора роутера с записью логов на USB
# Скрипт измеряет температуру процессора роутера с заданным интервалом (по умолчанию 1 минута), сохраняя данные в RAM. С заданным интервалом (по умолчанию 1 час) переносит данные из RAM на USB, вычисляя минимальную, максимальную и среднюю температуру за этот период с выводом в системный журнал веб-интерфейса роутера. При превышении заданного порога температуры (по умолчанию 60°C) также выводит предупреждение в системный журнал. Логи за предыдущий месяц автоматически архивируются в .gz на USB

# Автор: AksTis
# https://akstis.su/

# Версия: 1.0
# Дата: 30 Марта 2025
# Лицензия: MIT

# Зависимости: BusyBox с awk, basename, cat, cut, date, df, echo, grep, gzip, head, logger, mkdir, pidof, printf, sleep, sort, tail, wc
# Запуск: ./artemon.sh [interval_temp] [interval_log] [temp_alarm] [--debug|-d] &
#		  ./artemon.sh [interval_temp] [--interactive|-i]
# Пример 1: ./artemon.sh 60 3600 70 & (замеры каждые 60 сек, копирование на USB каждые 3600 сек, тревога при 70°C, знак & запускает скрипт в фоновом режиме)
# Пример 2: ./artemon.sh 30 300 50 -d (замеры каждые 30 сек, копирование на USB каждые 300 сек, тревога при 50°C, вывод отладки в консоль)
# Пример 3: ./artemon.sh 10 -i (Интерактивный режим: замеры каждые 10 сек, вывод в консоль)
# Пример 4: ./artemon.sh -i (Интерактивный режим: замеры каждые 60 сек, вывод в консоль)

### Как использовать этот скрипт ###

# 0. Убедитесь, что USB-накопитель монтируется в /mnt/sda1
# Если путь отличается (например, /mnt/usb), измените переменную USB_MOUNT в скрипте

# 1. Подключитесь к роутеру по SSH

# 2. Поместите скрипт в файл /jffs/scripts/artemon.sh
# Откройте файл для редактирования с помощью vi
#	vi /jffs/scripts/artemon.sh
# Нажмите i, чтобы войти в режим вставки
# Скопируйте весь текст скрипта и вставьте его в терминал
# Нажмите Esc, чтобы выйти из режима вставки
# Введите :wq и нажмите Enter, чтобы сохранить файл и закрыть vi

# 3. Сделайте скрипт исполняемым с помощью команды:
#	chmod +x /jffs/scripts/artemon.sh

# 4. Выполните скрипт вручную для проверки:
#	/jffs/scripts/artemon.sh &
# Знак & запускает скрипт в фоновом режиме (не нужен для интерактивного режима)

# 5. Проверьте системный журнал:
# Зайдите в веб-интерфейс роутера (обычно http://192.168.0.1), перейдите в System Log и найдите записи с тегом ARTeMon

# Установки
INTERVAL_TEMP=60									# Интервал замеров температуры (1 минута)
INTERVAL_LOG=3600									# Интервал вывода сообщений в системный журнал и копирования логов на USB (1 час)
TEMP_ALARM=60										# Температура тревоги (в целых градусах)
RAM_LOG="/tmp/temp_log"								# Путь для логов в RAM
USB_MOUNT="/mnt/sda1"								# Путь монтирования USB флешки (проверь свой)
USB_LOG_DIR="$USB_MOUNT/temp_log"					# Директория для логов на USB
TEMP_SENS="/sys/class/thermal/thermal_zone0/temp"	# Температурный сенсор (проверь свой)

# Проверка аргументов
INTERACTIVE=0
DEBUG=0
for arg in "$1" "$2" "$3" "$4" "$5"; do
	case "$arg" in
		"--interactive"|"-i")
			INTERACTIVE=1
			;;
		"--debug"|"-d")
			DEBUG=1
			;;
		*[!0-9]*|"")  # Пропускаем нечисловые аргументы или пустые строки
			;;
		*)
			if [ -z "$INTERVAL_TEMP_SET" ]; then
				INTERVAL_TEMP="$arg"
				INTERVAL_TEMP_SET=1
			elif [ -z "$INTERVAL_LOG_SET" ]; then
				INTERVAL_LOG="$arg"
				INTERVAL_LOG_SET=1
			elif [ -z "$TEMP_ALARM_SET" ]; then
				TEMP_ALARM="$arg"
				TEMP_ALARM_SET=1
			fi
			;;
	esac
done

# Отладка только для фонового режима
if [ "$INTERACTIVE" -eq 1 ]; then
	DEBUG=0
fi

# Функция для отладочных сообщений
YELLOW='\033[0;33m'
NC='\033[0m'
debug_msg() {
	if [ "$DEBUG" -eq 1 ]; then
		echo -e "${YELLOW}[DEBUG]${NC} $1"		# Вывод отладочных сообщений в консоль
	fi
}

# Сообщение о запуске (только для фонового режима)
if [ "$INTERACTIVE" -eq 0 ]; then
	logger -t "ARTeMon" "Скрипт запущен с параметрами: INTERVAL_TEMP=$INTERVAL_TEMP, INTERVAL_LOG=$INTERVAL_LOG, TEMP_ALARM=$TEMP_ALARM"
	debug_msg "Скрипт запущен с параметрами: INTERVAL_TEMP=$INTERVAL_TEMP, INTERVAL_LOG=$INTERVAL_LOG, TEMP_ALARM=$TEMP_ALARM"
fi

# Проверка наличия температурного сенсора
if [ ! -f "$TEMP_SENS" ]; then
	if [ "$INTERACTIVE" -eq 0 ]; then
		logger -t "ARTeMon" "Температурный сенсор не найден. Выполнение скрипта завершено"
		debug_msg "Температурный сенсор не найден. Выполнение скрипта завершено"
	else
		echo "Температурный сенсор не найден: $TEMP_SENS"
	fi
	exit 1
fi

# Проверка, запущен ли скрипт (только для фонового режима)
if [ "$INTERACTIVE" -eq 0 ] && [ -n "$(pidof "$(basename "$0")")" ] && [ "$(pidof "$(basename "$0")")" != "$$" ]; then
	logger -t "ARTeMon" "Скрипт уже запущен. Выполнение скрипта завершено"
	debug_msg "Скрипт уже запущен. PID процесса: $(pidof "$(basename "$0")"). Выполнение скрипта завершено"
	exit 1
fi

# Инициализация файла в RAM (только для фонового режима)
if [ "$INTERACTIVE" -eq 0 ] && [ ! -f "$RAM_LOG" ]; then
	> "$RAM_LOG"	# Cоздаём пустой файл
	debug_msg "Создан файл RAM-лога: $RAM_LOG"
fi

# Интерактивный режим
if [ "$INTERACTIVE" -eq 1 ]; then
	while true; do
		TEMP=$(cat "$TEMP_SENS")
		TEMP_CPU="$((TEMP / 1000)).$(((TEMP % 1000) / 100))"
		TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
		echo "$TIMESTAMP: $TEMP_CPU °C"
		sleep "$INTERVAL_TEMP"
	done
fi

# Основной цикл (только для фонового режима)
if [ "$INTERACTIVE" -eq 0 ]; then
	while true; do
		# Читаем температуру в °C
		TEMP=$(cat "$TEMP_SENS")
		TEMP_CPU="$((TEMP / 1000)).$(((TEMP % 1000) / 100))"	# Роутер не умеет bc поэтому такой костыль для округления до десятых
		debug_msg "Измерена температура: $TEMP_CPU°C (сырые данные: $TEMP)"

		# Проверка на высокую температуру (сравнение только целой части)
		TEMP_CPU_INTEGER=$((TEMP / 1000))
		if [ "$TEMP_CPU_INTEGER" -ge "$TEMP_ALARM" ]; then
			logger -t "ARTeMon" "ВНИМАНИЕ: Температура $TEMP_CPU °C превысила $TEMP_ALARM°C!"
			debug_msg "Температура превысила порог: $TEMP_CPU > $TEMP_ALARM. Отправлено сообщение в системный журнал"
		fi

		# Текущая дата и время
		TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
		debug_msg "Текущая метка времени: $TIMESTAMP"

		# Пишем в RAM-лог
		echo "$TIMESTAMP,$TEMP_CPU" >> "$RAM_LOG"
		debug_msg "Запись в RAM-лог: $TIMESTAMP,$TEMP_CPU"

		# Проверяем время для копирования
		CURRENT_TIME=$(date +%s)
		if [ -z "$LAST_COPY_TIME" ]; then
			LAST_COPY_TIME=$CURRENT_TIME
			debug_msg "Инициализация LAST_COPY_TIME: $LAST_COPY_TIME"
		fi

		TIME_DIFF=$((CURRENT_TIME - LAST_COPY_TIME))
		if [ "$TIME_DIFF" -ge "$INTERVAL_LOG" ]; then
			debug_msg "Копирование логов на USB: TIME_DIFF=$TIME_DIFF >= INTERVAL_LOG=$INTERVAL_LOG"

			# Вычисляем мин, макс и среднюю температуру за интервал
			TEMP_VALUES=$(cat "$RAM_LOG" | cut -d',' -f2)
			if [ -n "$TEMP_VALUES" ]; then
				MIN_TEMP=$(echo "$TEMP_VALUES" | sort -n | head -n 1)
				MAX_TEMP=$(echo "$TEMP_VALUES" | sort -n | tail -n 1)
				AVG_TEMP=$(echo "$TEMP_VALUES" | awk '{sum+=$1; count++} END {printf "%.1f", sum/count}')

				# Логируем в системный журнал
				INTERVAL=$((INTERVAL_LOG / 60))
				logger -t "ARTeMon" "Температура за последние $INTERVAL минут: Мин: $MIN_TEMP °C, Макс: $MAX_TEMP °C, Сред: $AVG_TEMP °C"
				debug_msg "Статистика за $INTERVAL минут отправлена в системный журнал: Мин=$MIN_TEMP, Макс=$MAX_TEMP, Сред=$AVG_TEMP"

				# Проверяем наличие USB флешки и создаём директорию
				if [ -d "$USB_MOUNT" ] && grep -q "$USB_MOUNT" /proc/mounts; then
					FREE_SPACE=$(df -k "$USB_MOUNT" | tail -1 | awk '{print $4}')	# Свободное место в килобайтах
					if [ -n "$FREE_SPACE" ] && [ "$FREE_SPACE" -gt 102400 ]; then	# Больше 100 МБ
						debug_msg "На USB свободно $FREE_SPACE КБ ($((FREE_SPACE / 1024)) МБ)"
						mkdir -p "$USB_LOG_DIR"		# Создаём папку для логов, если её нет
						debug_msg "Создана/проверена директория: $USB_LOG_DIR"

						# Архивирование логов за предыдущий месяц
						CURRENT_MONTH=$(date "+%m")
						CURRENT_YEAR=$(date "+%Y")
						PREV_MONTH=$((CURRENT_MONTH - 1))
						PREV_YEAR=$CURRENT_YEAR
						if [ "$PREV_MONTH" -eq 0 ]; then
							PREV_MONTH=12
							PREV_YEAR=$((CURRENT_YEAR - 1))
						fi
						PREV_MONTH=$(printf "%02d" "$PREV_MONTH")	# Добавляем ведущий ноль (01, 02 и т.д.)
						PREV_LOG_FILE="$USB_LOG_DIR/$PREV_MONTH.$PREV_YEAR.txt"
						if [ -f "$PREV_LOG_FILE" ]; then
							gzip "$PREV_LOG_FILE"
							debug_msg "Лог $PREV_LOG_FILE заархивирован в $PREV_LOG_FILE.gz"
						fi
						
						# Формируем имя файла на основе текущего месяца и года
						MONTH_YEAR=$(date "+%m.%Y")
						USB_LOG_FILE="$USB_LOG_DIR/$MONTH_YEAR.txt"
						debug_msg "Текущий файл лога на USB: $USB_LOG_FILE"

						# Копируем данные на USB
						cat "$RAM_LOG" >> "$USB_LOG_FILE"
						COUNT=$(echo "$TEMP_VALUES" | wc -l)
						debug_msg "Лог сохранён на USB: $USB_LOG_FILE (добавлено $COUNT записей)"

					else
						[ -z "$FREE_SPACE" ] && FREE_SPACE=0	# Если df не сработал, считаем, что места нет
						logger -t "ARTeMon" "На USB недостаточно места. Свободно $((FREE_SPACE / 1024)) МБ, нужно больше 100 МБ. Логи не сохранены"
						debug_msg "На USB свободно $FREE_SPACE КБ ($((FREE_SPACE / 1024)) МБ). Нужно больше 100 МБ. Логи не сохранены"
					fi

				else
					logger -t "ARTeMon" "USB не подключён. Сохранение логов на USB не произведено"
					debug_msg "Не удалось скопировать логи на USB. Накопитель не смонтирован или директория $USB_MOUNT недоступна"
				fi

			else
				logger -t "ARTeMon" "Нет данных о температуре за последний интервал"
				debug_msg "Нет данных о температуре за последний интервал"
			fi

			# Очищаем RAM-лог после обработки
			> "$RAM_LOG"
			debug_msg "RAM-лог очищен"
			LAST_COPY_TIME=$CURRENT_TIME
			debug_msg "Обновлено LAST_COPY_TIME: $LAST_COPY_TIME"
		fi

		# Ждём
		debug_msg "Ожидание следующего замера $INTERVAL_TEMP секунд"
		sleep "$INTERVAL_TEMP"
	done

fi
