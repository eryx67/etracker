# README #

Simple BitTorrent tracker

It supports HTTP and UDP announce and scrape requests.

No IPv6 support yet.

## Configuration

Look at src/etracker.app.src

## Munin plugin

Plugin and example configuration are in munin directory.

Plugin compilation was tested with SBCL 1.1.*

## HTTP requests

### announce
<pre>
    server-http-address/announce?...
</pre>

### scrape
<pre>
    server-http-address/scrape
    server-http-address/scrape?...
</pre>

### stats
<pre>
    server-http-address/_stats
    server-http-address/_stats/[net|db|jobs]
</pre>
