.PHONY: ping lint check apply shell

ping:          ## проверить связь
	ansible web -m ping

lint:          ## синтаксис
	ansible-playbook site.yml --syntax-check

check:         ## сухой прогон с показом изменений
	ansible-playbook site.yml --check --diff

apply:         ## применить
	ansible-playbook site.yml

shell:         ## зайти на сервер
	ssh yesinit@176.109.107.173
