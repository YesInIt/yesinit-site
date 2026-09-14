# yesinit-site

Инфраструктура блога [yesinit.tech](https://yesinit.tech). Конфигурация сервера
описана кодом: `git pull` на управляющей машине → `ansible-playbook site.yml`
на целевую ноду.

## Состав

| Каталог | Что внутри |
|---|---|
| `inventory/` | описание хостов |
| `group_vars/` | общие переменные |
| `roles/docker` | Docker Engine + compose-плагин из официального репозитория |
| `roles/ghost` | docker compose: Ghost 6, MySQL 8, Caddy |
| `roles/backup` | restic → S3 (Cloud.ru Object Storage) по расписанию |
| `site.yml` | основной плейбук |

## Как это работает

`roles/ghost` кладёт на сервер (`/opt/yesinit.tech/`) `docker-compose.yml` и
`Caddyfile`, затем поднимает стек:

- **mysql** — MySQL 8, том `mysql_data`, без публикации портов наружу;
- **ghost** — Ghost 6, том `ghost_content`, без публикации портов наружу;
- **caddy** — единственный сервис, publish'ящий 80/443. Он же сам получает и
  продлевает сертификат Let's Encrypt (ACME HTTP-01) — отдельный certbot или
  cron для перевыпуска не нужны, это встроено в Caddy.

Пароли для MySQL и пользователя Ghost генерируются один раз при первом
прогоне (`lookup('password', ...)`) и сохраняются в `.secrets/` рядом с
плейбуком на управляющей машине — в git не попадают (см. `.gitignore`), при
повторных прогонах переиспользуются.

## Контрольная нода

Ansible не работает на Windows. Варианта два.

**WSL2 (рекомендуется).**

```bash
wsl --install -d Ubuntu          # в PowerShell, один раз
```

Дальше внутри Ubuntu:

```bash
sudo apt update && sudo apt install -y ansible git
git clone <repo> && cd yesinit-site
```

Ключ в inventory не прописан — пробрасывается через ssh-agent (`ssh-add`
на хосте, `ssh -A` / форвардинг агента в WSL или в агенте, который вы
используете для деплоя).

**Запуск на самом сервере.** Если WSL ставить не хочется:

```bash
ssh yesinit@176.109.107.173
sudo apt install -y ansible git
git clone <repo> ~/yesinit-site && cd ~/yesinit-site
ansible-playbook -i localhost, -c local site.yml
```

## Перед первым запуском

1. **DNS.** `yesinit.tech` (A-запись) должен указывать на `176.109.107.173` —
   иначе Let's Encrypt не сможет пройти HTTP-01 challenge и Caddy не выдаст
   сертификат.
2. **Firewall облака.** Порты 80 и 443 должны быть открыты входящими в
   security group / панели Cloud.ru (роль `security` с ufw/fail2ban на этом
   этапе сознательно не подключена — минимальный вариант для первого запуска).

## Первый запуск

```bash
ansible web -m ping                        # связь есть?
ansible-playbook site.yml --syntax-check   # синтаксис
ansible-playbook site.yml --check --diff   # что изменится
ansible-playbook site.yml                  # применить
```

Или через `make ping`, `make check`, `make apply`.

Первый прогон займёт минуту-другую: MySQL инициализируется, Ghost ждёт её
healthcheck, Caddy запрашивает сертификат. Через `docker logs caddy -f` на
сервере видно процесс выпуска сертификата.

## Проверка после прогона

```bash
curl -I https://yesinit.tech        # 200/301, валидный сертификат
docker ps                           # три контейнера: mysql, ghost, caddy
docker logs caddy --tail 50         # без ошибок ACME
```

`docker` без `sudo` заработает после повторного входа по SSH: членство в
группе применяется к новой сессии.

## Бэкапы

`roles/backup` ставит `restic` и systemd-таймер, который раз в сутки (по
умолчанию 03:30 UTC):

1. снимает дамп всех баз MySQL (`docker exec ghost-mysql mysqldump`);
2. копирует контент Ghost из контейнера (`docker cp ghost:/var/lib/ghost/content`);
3. кладёт оба зашифрованным снапшотом в S3-бакет Cloud.ru Object Storage;
4. подчищает старые снапшоты (`--keep-daily 7 --keep-weekly 4 --keep-monthly 6`).

Юнит-файлы: `/etc/systemd/system/restic-backup.{service,timer}`, скрипт —
`/usr/local/bin/yesinit-backup.sh`, креды — `/etc/restic/env` (root:root,
0600).

### Настройка перед первым запуском роли

1. В [console.cloud.ru](https://console.cloud.ru) → **Хранение данных →
   Object Storage** — создать бакет (например, `yesinit-tech-backups`),
   доступ `Private`.
2. Там же, **Параметры работы с API** — посмотреть `tenant_id`.
3. Правый верхний угол → профиль → **Мои учётные данные** → вкладка
   **Ключи доступа** → **Создать ключ доступа** — сохранить `Key ID` и
   `Key Secret` (Key Secret показывается один раз).
4. Скопировать `group_vars/all/vault.yml.example` → `group_vars/all/vault.yml`
   (в `.gitignore`, в git не попадает) и заполнить:
   ```yaml
   backup_s3_bucket: yesinit-tech-backups
   backup_s3_access_key: "<tenant_id>:<key_id>"
   backup_s3_secret_key: "<key_secret>"
   ```

Пароль шифрования репозитория restic (`restic_password`) генерируется
автоматически, как и пароли MySQL/Ghost, и сохраняется в `.secrets/`.
**В отличие от них он критичен** — без него зашифрованные снапшоты в S3
не восстановить никак, даже с доступом к самому бакету. Скопируйте
`.secrets/restic_password` в отдельный менеджер паролей, не полагаясь
только на диск управляющей машины.

### Запуск

```bash
ansible-playbook site.yml --tags backup       # выложить конфигурацию и таймер
ansible-playbook site.yml --tags backup-now   # прогнать бэкап сразу, для проверки
```

Проверить на сервере:

```bash
sudo systemctl list-timers restic-backup.timer
sudo journalctl -u restic-backup.service --since today
sudo -E bash -c 'source /etc/restic/env && restic snapshots'
```

Важно про `RESTIC_REPOSITORY` для Cloud.ru: без схемы (`s3:s3.cloud.ru/bucket/...`,
**не** `s3:https://s3.cloud.ru/...`) — с явным `https://` restic падает с
`client.MakeBucket: Tenant does not exist`, хотя тот же ключ и бакет
прекрасно работают через обычный S3 API. Так рекомендует сам Cloud.ru.

### Восстановление

```bash
source /etc/restic/env

restic snapshots                              # найти нужный snapshot ID
restic restore <snapshot-id> --target /tmp/restore

# база — накатить дамп обратно в контейнер:
docker exec -i ghost-mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' \
  < /tmp/restore/tmp/*/mysql-all-databases.sql

# контент Ghost — скопировать обратно в контейнер (сервис можно не
# останавливать, Ghost подхватит файлы, но безопаснее сделать это при
# остановленном контейнере):
docker cp /tmp/restore/tmp/*/ghost-content/. ghost:/var/lib/ghost/content/
```

## Известная особенность: ufw и Docker

Docker пишет правила напрямую в iptables и обходит ufw (актуально, когда роль
`security` будет подключена обратно). Поэтому наружу публикует порты только
Caddy — Ghost и MySQL сидят в изолированной docker-сети `internal`.

## Дальше

- [ ] роль `common` / `security` — sshd hardening, ufw, fail2ban (были в
      прошлой версии репозитория, здесь пока сознательно убраны ради
      простоты первого запуска)
- [ ] `ansible-pull` по таймеру вместо ручного запуска
- [ ] учения по восстановлению
