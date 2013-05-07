-- psql -d template1 -U postgres
CREATE USER etracker
WITH PASSWORD 'etracker'
     CREATEDB;

CREATE DATABASE etracker WITH OWNER = etracker ENCODING = 'UTF8';
GRANT ALL ON DATABASE etracker TO etracker;
\c etracker
CREATE LANGUAGE plpgsql;
CREATE UNLOGGED TABLE torrent_info(
       info_hash BYTEA PRIMARY KEY,
       leechers INTEGER DEFAULT 0,
       seeders INTEGER DEFAULT 0,
       completed INTEGER DEFAULT 0,
       name VARCHAR,
       mtime TIMESTAMP DEFAULT now(),
       ctime TIMESTAMP  DEFAULT now()
);

CREATE UNLOGGED TABLE torrent_user(
       id SERIAL PRIMARY KEY,
       info_hash BYTEA NOT NULL,
       peer_id BYTEA NOT NULL,
       address INTEGER ARRAY,
       port INTEGER,
       event VARCHAR,
       downloaded INTEGER DEFAULT 0,
       uploaded INTEGER DEFAULT 0,
       left_bytes INTEGER DEFAULT 0,
       finished BOOLEAN DEFAULT false,
       mtime  TIMESTAMP  DEFAULT now(),
       CONSTRAINT torrent_user_info_hash_peer_id_idx UNIQUE(info_hash, peer_id)
);
CREATE INDEX torrent_user_seeders_idx ON torrent_user(info_hash)
       WHERE finished = true and event != 'stopped';
CREATE INDEX torrent_user_leechers_idx ON torrent_user(info_hash)
       WHERE finished = false and event != 'stopped';

CREATE UNLOGGED TABLE connection_info(
       id BYTEA PRIMARY KEY,
       mtime  TIMESTAMP  DEFAULT now()
);
