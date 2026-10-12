#!/bin/sh
# LXC 104 の中で root として実行する。リポジトリは /opt/tennis に clone 済みとする
set -eu

id tc >/dev/null 2>&1 || useradd --system --home /var/lib/tournament-calendar --shell /usr/sbin/nologin tc
install -d -o tc -g tc /var/lib/tournament-calendar
[ -f /etc/tournament-calendar.env ] || install -m 600 "$(dirname "$0")/tournament-calendar.env.example" /etc/tournament-calendar.env

cd /opt/tennis
corepack enable
pnpm install --frozen-lockfile --filter tournament-calendar

cp TournamentCalendar/deploy/*.service TournamentCalendar/deploy/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now tournament-calendar-web.service tournament-calendar-crawl.timer tournament-calendar-notify.timer
