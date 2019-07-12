import std.stdio;
import std.conv;
import std.format;
import std.datetime;
import core.thread;

import std.experimental.logger;

import redisd;

void job() {
    version(std) {
        auto redis = new Client();
    }
    version(hio) {
        auto redis = new Client("redis://localhost", &hioConnectionMaker);
    }
    version (vibe) {
        auto redis = new Client("redis://localhost", &vibeConnectionMaker);
    }
    auto v = redis.set("a", "0");
    writefln("response set: %s", v);
    v = redis.execCommand("hgkhjgkjhgk");
    writefln("response: %s", v);
    v = redis.execCommand("KEYS", "*");
    writefln("response: %s", v);
    v = redis.get("*");
    writefln("response: %s", v);
    v = redis.execCommand("MGET", "a", "*", "a");
    writefln("MGET response: %s", v);
    v = redis.execCommand("SET", "b", "1");
    writefln("SET response: %s", v);
    v = redis.execCommand("INCR", "b");
    writefln("INCR response: %s", v);
    RedisdValue[] commands;
    commands ~= redis.makeCommand("INCR", "b");
    commands ~= redis.makeCommand("SET", "a", "0");
    commands ~= redis.makeCommand("INCR", "a");
    commands ~= redis.makeCommand("DEL", "mylist");
    v = redis.transaction(commands);
    writefln("transaction=%s", v);
    commands.length = 0;
    foreach (i; 0 .. 100) {
        commands ~= redis.makeCommand("RPUSH", "mylist", to!string(i));
    }
    auto vs = redis.pipeline(commands);
    writeln(vs);
    v = redis.execCommand("LRANGE", "mylist", "0", "100");
    writeln(v);
    redis.close();
}

// Main functions for different io drivers
// run with dub run -c std
// run with dub run -c vibe
// run with dub run -c hio

version(std) {
    void main() {
        globalLogLevel = LogLevel.info;
        job();
    }
}

version(vibe) {
    import vibe.vibe;
    void main() {
        globalLogLevel = std.experimental.logger.LogLevel.info;
        runTask({
            try{
                job();
            }
            finally {
                exitEventLoop();
            }
        });
        runEventLoop();
    }
}

version(hio) {
    import hio.scheduler;
    void main() {
        globalLogLevel = LogLevel.info;
        App(&job);
    }
}