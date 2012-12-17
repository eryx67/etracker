# README #

# Etracker #

  Простой BitTorrent трекер.

# Установка #


## Зависимости ##

* Erlang R15

## Конфигурация ##

    cd rel/files

* _sys.config_ файл конфигурации приложения
* _vm.args_ параметры виртуальной машины Erlang

Наиболее интересные параметры приложения:

    {http_port, 8080},            % port to listen for requests
    {http_ip, "127.0.0.1"},       % server address
    {http_num_acceptors, 16},     % pool of request acceptors
    {answer_compact, false},      % always return compact list of peers
    {answer_max_peers, 50},       % max number of peers to return
    {answer_interval, 1800},      % client interval value in answer to
                                  % announce
    {clean_interval, 2700},        % database garbage clearing interval
    {scrape_request_interval, 1800}, % minimum number of seconds to wait before
                                     % scraping the tracker again

## Сборка ##

    make

"Готовое к употреблению" приложение будет собрано в директории rel/etracker.

Структура катологов приложения:

* TOP_DIR (etracker)
  * bin/etracker исполняемый файл приложения
  * log логи приложения
  * data файлы базы данных
  * erts-*, lib, releases служебные файлы виртуальной машины

## Запуск ##

    path_to_etracker_dir/bin/etracker start

## Останов ##

    path_to_etracker_dir/bin/etracker stop
