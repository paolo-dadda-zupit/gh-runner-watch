# gh-runner-watch.sh

Script per controllare lo stato di un GitHub Actions self-hosted runner (servizio `svc.sh`) e applicare contromisure:

- se **running** → OK
- se **failed (Result: oom-kill)** → notifica + tenta **stop/start** + ricontrollo
- se **non running** (altro motivo) → notifica

> Nota: lo script esegue `svc.sh` **dentro la directory del runner** (fa `cd` nel runner root), perché `svc.sh` richiede di essere lanciato da lì.

---

## Requisiti

- bash
- `sudo` (per leggere stato e avviare/fermare il servizio)
- `curl` (solo se abiliti Slack)
- Accesso al runner root (es. `/opt/github-runner/...`)

---

## Installazione veloce

1) Copia lo script dove preferisci, ad esempio:

   sudo cp gh-runner-watch.sh /usr/local/bin/gh-runner-watch.sh  
   sudo chmod 700 /usr/local/bin/gh-runner-watch.sh

2) (Opzionale) Config Slack in `/etc/gh-runner-watch.conf`:

   sudo tee /etc/gh-runner-watch.conf >/dev/null <<'EOC'
   SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
   EOC
   sudo chmod 600 /etc/gh-runner-watch.conf

---

## Uso manuale

### Esecuzione base (runner di default)

    /usr/local/bin/gh-runner-watch.sh --manual

Se il runner è attivo, in manuale stampa `running`.  
Se non lo è, stampa un messaggio con dettagli dello stato.

### Personalizzare il path del runner (override)

    /usr/local/bin/gh-runner-watch.sh --manual --runner-dir "/opt/github-runner/NOME_RUNNER"

Esempio:

    /usr/local/bin/gh-runner-watch.sh --manual --runner-dir "/opt/github-runner/pipeline-agents2-container-1"

### Passare un webhook Slack al volo (override)

    /usr/local/bin/gh-runner-watch.sh --manual --slack-webhook "https://hooks.slack.com/services/XXX/YYY/ZZZ"

---

## Modalità scheduled (cron ogni 3 minuti)

### Opzione A (consigliata): cron come root

    sudo crontab -e

Aggiungi:

    */3 * * * * /usr/local/bin/gh-runner-watch.sh --scheduled >> /var/log/gh-runner-watch.cron.log 2>&1

### Opzione B: cron come utente (con sudoers mirato)

Apri sudoers con:

    sudo visudo

Aggiungi (sostituisci `NOME_UTENTE` e il path del runner):

    NOME_UTENTE ALL=(root) NOPASSWD: /opt/github-runner/pipeline-agents2-container-1/svc.sh status, \
      /opt/github-runner/pipeline-agents2-container-1/svc.sh stop, \
      /opt/github-runner/pipeline-agents2-container-1/svc.sh start

Poi nel crontab dell’utente:

    crontab -e

Aggiungi:

    */3 * * * * /usr/local/bin/gh-runner-watch.sh --scheduled >> $HOME/gh-runner-watch.cron.log 2>&1

---

## Configurazione

### File di config (opzionale)

Default: `/etc/gh-runner-watch.conf`

Puoi passare un file diverso:

    /usr/local/bin/gh-runner-watch.sh --scheduled --config "/percorso/mio.conf"

Variabili supportate:
- `SLACK_WEBHOOK_URL="..."`

---

## Log e lock

- Log (se scrivibile): `/var/log/gh-runner-watch.log`  
  fallback: `$HOME/gh-runner-watch.log`
- Lock per evitare overlap (cron): `/var/lock/gh-runner-watch.lock`  
  fallback: `/tmp/gh-runner-watch.lock`

---

## Exit code (utile per monitoring)

- `0`  → runner running
- `10` → OOM-kill rilevato, restart riuscito
- `11` → OOM-kill rilevato, restart fallito
- `20` → non running (motivo diverso da OOM-kill)
- `30` → errore script (path runner/svc.sh non valido, ecc.)

---

## Troubleshooting

### Verifica a mano il runner root

    cd /opt/github-runner/pipeline-agents2-container-1
    sudo ./svc.sh status

### Debug verbose dello script

    bash -x /usr/local/bin/gh-runner-watch.sh --manual --runner-dir "/opt/github-runner/..."