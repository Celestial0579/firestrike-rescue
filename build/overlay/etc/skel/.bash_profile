# Firestrike Rescue: Assistent startet automatisch auf tty1.
[ -f ~/.bashrc ] && . ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
if [ "$(tty)" = "/dev/tty1" ] && [ -z "${FRS_STARTED:-}" ]; then
	export FRS_STARTED=1
	frs
	echo
	echo "Assistent beendet. 'frs' startet ihn erneut."
fi
