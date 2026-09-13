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

## Известная особенность: ufw и Docker

Docker пишет правила напрямую в iptables и обходит ufw (актуально, когда роль
`security` будет подключена обратно). Поэтому наружу публикует порты только
Caddy — Ghost и MySQL сидят в изолированной docker-сети `internal`.

## Дальше

- [ ] роль `common` / `security` — sshd hardening, ufw, fail2ban (были в
      прошлой версии репозитория, здесь пока сознательно убраны ради
      простоты первого запуска)
- [ ] роль `backup` — restic по расписанию (тома `mysql_data`, `ghost_content`)
- [ ] `ansible-pull` по таймеру вместо ручного запуска
- [ ] учения по восстановлению
