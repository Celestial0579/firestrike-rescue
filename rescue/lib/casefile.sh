# shellcheck shell=bash
# Falldatei (case.env) eines Rettungsfalls lesen und schreiben.
#
# Die Datei liegt im Fallordner auf der Ziel-Disk. Wer eine unterbrochene Rettung fortsetzt,
# liest sie von einem Datenträger, den jemand angeschlossen und ausgewählt hat. Sie wird
# deshalb nie als Shell-Code eingelesen (kein "." und kein "source"), sondern als Daten:
#   - Jede Zeile hat die Form SCHLÜSSEL="Wert".
#   - Erlaubt sind nur die Schlüssel aus CASEFILE_KEYS, jeder höchstens einmal.
#   - Jeder Wert muss zum Muster seines Schlüssels passen (casefile_pattern).
#   - Kein Wert enthält Steuerzeichen oder eines der Zeichen " $ ` \. Das sind die Zeichen,
#     die zwischen doppelten Anführungszeichen für die Shell eine Bedeutung haben.
# Verstößt eine Datei dagegen, wird sie ganz abgelehnt. CASEFILE_ERROR nennt Zeile und Grund.
#
# Geschrieben wird mit denselben Prüfungen, erst in eine neue Datei, die dann die alte ersetzt.

# Alle Schlüssel, in der Reihenfolge, in der sie geschrieben werden.
CASEFILE_KEYS=(SRC_ID SRC_SIZE SRC_LABEL TARGET_ID STATE SRC_PATH STARTED PHASE PHASE_DONE FINISHED)
# Ohne diese ist ein Fall nicht verwendbar.
CASEFILE_REQUIRED=(SRC_ID SRC_SIZE STATE)

declare -gA CASEFILE=()
CASEFILE_ERROR=""

# casefile_pattern SCHLÜSSEL   Gibt das Muster für den Wert aus. Rückgabe 1 bei unbekanntem Schlüssel.
casefile_pattern() {
	case $1 in
	# Kennung einer Disk: Seriennummer, WWN oder Gerätepfad unter /dev. Der Zeichenvorrat ist der,
	# den udev in Seriennummern durchlässt, ohne "$".
	SRC_ID | TARGET_ID) echo '^(/dev/[A-Za-z0-9][A-Za-z0-9._/+:=@#-]{0,190}|[A-Za-z0-9][A-Za-z0-9 #+.:=@_/%?,-]{0,199})$' ;;
	SRC_SIZE) echo '^[0-9]{1,20}$' ;;
	# Freier Text für den Bericht. Was nicht hineindarf, regelt casefile_value_ok.
	SRC_LABEL) echo '^.{1,800}$' ;;
	SRC_PATH) echo '^/dev/[A-Za-z0-9][A-Za-z0-9._/+:=@#-]{0,190}$' ;;
	STATE) echo '^(new|running|interrupted|done)$' ;;
	PHASE | PHASE_DONE) echo '^[0-3]$' ;;
	# Zeitstempel, wie "date -Is" ihn schreibt.
	STARTED | FINISHED) echo '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$' ;;
	*) return 1 ;;
	esac
}

# casefile_value_ok SCHLÜSSEL WERT   Prüft einen Wert. Bei Rückgabe 1 steht der Grund in CASEFILE_ERROR.
# Geprüft wird Byte für Byte (Locale C), damit das Ergebnis nicht von der Umgebung abhängt.
casefile_value_ok() {
	local LC_ALL=C key=$1 value=$2 pattern
	local forbidden='[[:cntrl:]"$`\]'
	if ! pattern=$(casefile_pattern "$key"); then
		CASEFILE_ERROR="unbekannter Schlüssel $key"
		return 1
	fi
	if [[ $value =~ $forbidden ]]; then
		CASEFILE_ERROR="der Wert von $key enthält ein unzulässiges Zeichen (Steuerzeichen, Anführungszeichen, \$, Backtick oder Backslash)"
		return 1
	fi
	if [[ ! $value =~ $pattern ]]; then
		CASEFILE_ERROR="der Wert von $key hat nicht die erwartete Form"
		return 1
	fi
	# Ein Gerätepfad zeigt nicht über ".." aus /dev heraus.
	case $key in
	SRC_ID | TARGET_ID | SRC_PATH)
		if [[ $value == /* && $value == *..* ]]; then
			CASEFILE_ERROR="der Wert von $key ist kein Gerätepfad unter /dev"
			return 1
		fi
		;;
	esac
	return 0
}

# casefile_clean_text TEXT   Macht aus beliebigem Text einen zulässigen Wert für SRC_LABEL:
# höchstens 200 Zeichen, unzulässige Zeichen werden zu "_".
casefile_clean_text() {
	local s=${1:0:200}
	local LC_ALL=C
	s=${s//[[:cntrl:]\"\$\`\\]/_}
	printf '%s' "${s:-_}"
}

# casefile_dirname_ok NAME   Ist NAME ein Name, wie der Assistent ihn für Fallordner vergibt?
# Der Name eines Fallordners kommt beim Fortsetzen von der Ziel-Disk und steht danach in Menüs
# und in Befehlszeilen. Erlaubt sind deshalb nur Buchstaben, Ziffern, Punkt, Unterstrich und
# Bindestrich, am Anfang ein Buchstabe oder eine Ziffer, höchstens 200 Zeichen. Damit kann ein
# Name weder als Option gelesen werden (kein "-" am Anfang) noch als Befehl (keine Leerzeichen,
# Anführungszeichen oder Steuerzeichen) noch aus FRS/ hinausführen (kein "/" und kein "..").
casefile_dirname_ok() {
	local LC_ALL=C
	[[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$ ]]
}

# casefile_load DATEI   Liest und prüft die Falldatei und füllt das Feld CASEFILE.
# Rückgabe 1 bei jedem Verstoß; CASEFILE ist dann leer.
casefile_load() {
	local LC_ALL=C file=$1 line key value n=0
	local form='^([A-Z_]+)="(.*)"$'
	CASEFILE=()
	CASEFILE_ERROR=""
	if [[ -L $file || ! -f $file ]]; then
		CASEFILE_ERROR="$file ist keine gewöhnliche Datei"
		return 1
	fi
	if [[ ! -r $file ]]; then
		CASEFILE_ERROR="$file ist nicht lesbar"
		return 1
	fi
	while IFS= read -r line || [[ -n $line ]]; do
		n=$((n + 1))
		line=${line%$'\r'}
		[[ -z $line ]] && continue
		if ((n > 100 || ${#line} > 1000)); then
			CASEFILE_ERROR="Zeile $n: die Datei ist länger, als eine Falldatei sein kann"
		elif [[ ! $line =~ $form ]]; then
			CASEFILE_ERROR="Zeile $n hat nicht die Form SCHLÜSSEL=\"Wert\""
		else
			key=${BASH_REMATCH[1]}
			value=${BASH_REMATCH[2]}
			if [[ -v CASEFILE[$key] ]]; then
				CASEFILE_ERROR="Zeile $n: der Schlüssel $key steht doppelt in der Datei"
			elif ! casefile_value_ok "$key" "$value"; then
				CASEFILE_ERROR="Zeile $n: $CASEFILE_ERROR"
			fi
		fi
		if [[ -n $CASEFILE_ERROR ]]; then
			CASEFILE=()
			return 1
		fi
		CASEFILE[$key]=$value
	done 2>/dev/null <"$file"
	for key in "${CASEFILE_REQUIRED[@]}"; do
		if [[ ! -v CASEFILE[$key] ]]; then
			CASEFILE_ERROR="der Schlüssel $key fehlt"
			CASEFILE=()
			return 1
		fi
	done
	return 0
}

# casefile_get SCHLÜSSEL [VORGABE]   Gibt den geladenen Wert aus, sonst die Vorgabe.
casefile_get() {
	printf '%s' "${CASEFILE[$1]:-${2:-}}"
}

# casefile_peek DATEI SCHLÜSSEL   Liest einen Wert aus einer Falldatei, ohne CASEFILE zu verändern.
casefile_peek() (
	casefile_load "$1" && casefile_get "$2"
)

# casefile_source_check SERIENNUMMER WWN GRÖSSE
# Vergleicht eine Disk, die der Techniker als Quelle gewählt hat, mit dem geladenen Fall.
# Die Falldatei wählt nie selbst eine Disk aus. Sie kann der Wahl des Technikers nur zustimmen
# oder ihr widersprechen. Rückgabe:
#   0  Seriennummer oder WWN stimmen mit SRC_ID überein und die Größe mit SRC_SIZE.
#   3  Die Falldatei kennt für die Quelle nur einen Gerätepfad. Ein Pfad ist keine Kennung, er
#      wechselt beim Umstecken. Übereinstimmend ist dann allein die Größe.
#   1  Die Disk ist nicht die Quelle dieses Falls. Der Grund steht in CASEFILE_ERROR.
casefile_source_check() {
	local serial=$1 wwn=$2 size=$3 id
	id=$(casefile_get SRC_ID)
	CASEFILE_ERROR=""
	if [[ -z $id ]]; then
		CASEFILE_ERROR="es ist kein Rettungsfall geladen"
		return 1
	fi
	if [[ $id != /dev/* && ! (-n $serial && $id == "$serial") && ! (-n $wwn && $id == "$wwn") ]]; then
		CASEFILE_ERROR="Seriennummer und WWN der Disk stimmen nicht mit dem Rettungsfall überein"
		return 1
	fi
	if [[ -z $size || $size != "$(casefile_get SRC_SIZE)" ]]; then
		CASEFILE_ERROR="die Größe der Disk stimmt nicht mit dem Rettungsfall überein"
		return 1
	fi
	[[ $id == /dev/* ]] && return 3
	return 0
}

# casefile_save DATEI   Schreibt CASEFILE in eine neue Datei und ersetzt damit die alte.
# Es wird nie in eine vorhandene Datei hineingeschrieben und nie durch eine Verknüpfung hindurch.
casefile_save() {
	local file=$1 tmp key content=""
	if [[ -L $file || (-e $file && ! -f $file) ]]; then
		CASEFILE_ERROR="$file ist keine gewöhnliche Datei"
		return 1
	fi
	for key in "${CASEFILE_KEYS[@]}"; do
		if [[ -v CASEFILE[$key] ]]; then
			content+="$key=\"${CASEFILE[$key]}\""$'\n'
		fi
	done
	if ! tmp=$(mktemp "$file.XXXXXX" 2>/dev/null); then
		CASEFILE_ERROR="$file lässt sich nicht schreiben"
		return 1
	fi
	# Die alte Datei wird erst ersetzt, wenn die neue vollständig geschrieben und gegengelesen
	# ist. Läuft die Ziel-Disk während der Rettung voll, bleibt so der letzte Stand stehen.
	if printf '%s' "$content" 2>/dev/null >"$tmp" && [[ $(<"$tmp") == "${content%$'\n'}" ]]; then
		# Der Assistent liest die Datei als Benutzer, geschrieben wird sie auch von root. Auf
		# exFAT und NTFS gibt es keine Dateirechte, dort darf chmod scheitern.
		chmod 644 "$tmp" 2>/dev/null || true
		if mv -f "$tmp" "$file"; then
			return 0
		fi
	fi
	rm -f "$tmp"
	CASEFILE_ERROR="$file lässt sich nicht schreiben"
	return 1
}

# casefile_set DATEI SCHLÜSSEL WERT   Prüft den Wert, setzt ihn in CASEFILE und schreibt die Datei neu.
# Vorher muss die Datei mit casefile_load oder casefile_create geladen bzw. angelegt worden sein.
casefile_set() {
	local file=$1 key=$2 value=$3
	casefile_value_ok "$key" "$value" || return 1
	CASEFILE[$key]=$value
	casefile_save "$file"
}

# casefile_create DATEI SCHLÜSSEL=WERT ...   Legt eine neue Falldatei an.
casefile_create() {
	local file=$1 pair key
	shift
	CASEFILE=()
	CASEFILE_ERROR=""
	for pair in "$@"; do
		key=${pair%%=*}
		if ! casefile_value_ok "$key" "${pair#*=}"; then
			CASEFILE=()
			return 1
		fi
		CASEFILE[$key]=${pair#*=}
	done
	casefile_save "$file"
}
