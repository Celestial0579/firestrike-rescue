# Firestrike Rescue: Assistent startet automatisch auf tty1.
[ -f ~/.bashrc ] && . ~/.bashrc
# ~/.local/bin hinten: Dort legt "claude install" die aktualisierte CLI ab. "claude" soll das
# Skript /usr/local/bin/claude bleiben, das sie ohne Projekt-Einstellungen startet.
export PATH="$PATH:$HOME/.local/bin"
if [ "$(tty)" = "/dev/tty1" ] && [ -z "${FRS_STARTED:-}" ]; then
	export FRS_STARTED=1
	frs
	echo
	echo "Assistent beendet. 'frs' startet ihn erneut."
fi
