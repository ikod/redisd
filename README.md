# redisd

redis client library for D.

Why this library?

 * Pluggable connection manager - you can use this library with any underlying transport, both sync and async.
 Currently supported std.socket, vibe sockets. Any other transport can be easily implemented.
 * redis connection url to control connection details. `redis`, `rediss`, `redis-socket` and any other scheme can be plugged in. Authentication, database selection, etc...
 * minimum overhead on handling network traffic.

Docs http://ikod.github.io/redisd/

Code sample:

```d
import redisd;

void main() {
    auto redis = new Client("redis://:secretpassword@localhost/");
    auto v = redis.set("a", 0);
    writefln("response: %s", v);
    v = redis.execCommand("KEYS", "*");
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

