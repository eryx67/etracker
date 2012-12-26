# README #

## Etracker
    Простой BitTorrent трекер.

## Установка

### Зависимости

  * Erlang R15


### Конфигурация
<pre>
   cd rel/files

</pre>

  * `sys.config` файл конфигурации приложения
  * `vm.args` параметры виртуальной машины `Erlang`

     Наиболее интересные параметры приложения:
<pre>
   {http_port, 8080},            % port to listen for requests
   {http_ip, "127.0.0.1"},       % server address
   {http_num_acceptors, 16},     % pool of request acceptors
   {answer_compact, false},      % always return compact list of peers
   {answer_max_peers, 50},       % max number of peers to return
   {answer_interval, 1800},      % client interval value in answer to announce
   {scrape_request_interval, 1800},  % minimum number of seconds to wait before
                                     % scraping the tracker again
   {clean_interval, 2700}        % database garbage clearing interval

</pre>

### Сборка
<pre>
  make

</pre>
    "Готовое к употреблению" приложение будет собрано в директории
    `rel/etracker`.
    Структура катологов приложения:

  * TOP_DIR (etracker)
  * bin/etracker исполняемый файл приложения
  * log логи приложения
  * data файлы базы данных
  * erts-*, lib, releases служебные файлы виртуальной машины


### Запуск
<pre>
   path_to_etracker_dir/bin/etracker start

</pre>

### Останов
<pre>
   path_to_etracker_dir/bin/etracker stop

</pre>

### Запросы HTTP

#### announce
<pre>
    server-http-address/announce?...

</pre>

#### scrape
<pre>
    erver-http-address/scrape
    server-http-address/scrape?...

</pre>

#### stats
<pre>
    server-http-address/stats
    server-http-address/stats?[id=val]*

</pre>
      где `val` имя интересующего параметра
      При запросе с `Content-Type` `application/json` ответ выдается в
      JSON формате:
<pre>
    {value: [{KeyName: KeyValue}]}

</pre>
      или
<pre>
    {error: Reason}

</pre>
      При запросе с `Content-Type` `text/html` ответ выдается в виде HTML.
      Запрос выдает и принимает следующие параметры:

  * `torrents` число известных трекеру торрентов
  * `seeders` число известных трекеру сидеров
  * `leechers` число известных трекеру личеров
  * `peers` общее число пиров

      Статистика по следующим параметрам ведется с момента последнего
      старта сервера:

  * `announces` число принятых `announce` запросов
  * `scrapes` число принятых `scrape` запросов
  * `invalid_queries` число отвергнутых `announce` запросов с
    некорректными параметрами

  * `failed_queries` число отвергнутых `announce` запросов, которые
    трекер не смог разобрать

  * `unknown_queries` число запросов на некорректные URL

  * `deleted_peers` число удаленных при очистке пиров, т.е. пиров, не
    завершивших протокол обмена сигналом `stopped` или не преславших
    `announce` в течении `announce_interval`
