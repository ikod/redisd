module redisd.client;

import std.typecons;
import std.stdio;
import std.algorithm;
import std.range;
import std.string;

import std.experimental.logger;

import redisd.connection;
import redisd.codec;

private immutable bufferSize = 4*1024;

class Client {

    private {
        string          _connect_string;
        ConnectionMaker _connection_maker;
        Connection      _connection;
        DecodeStream    _input_stream;
    }

    this(string connect_string="localhost:6379", ConnectionMaker connectionMaker=&stdConnectionMaker) @safe {
        _connect_string = connect_string;
        _connection_maker = connectionMaker;
        _connection = _connection_maker();
        _connection.connect(_connect_string);
        _input_stream = new DecodeStream();
    }

    RedisValue makeCommand(A...)(A args) {
        return redisValue(tuple(args));
    }

    RedisValue transaction(RedisValue[] commands) {
        RedisValue[] results;
        RedisValue r = this.execCommand("MULTI");
        foreach (c; commands) {
            exec(c);
        }
        r = this.execCommand("EXEC");
        return r;
    }

    RedisValue[] pipeline(RedisValue[] commands) {
        immutable(ubyte)[] data = commands.map!encode.join();
        _connection.send(data);
        RedisValue[] response;
        while (response.length < commands.length) {
            debug(redisd) tracef("response length=%d, commands.length=%d", response.length, commands.length);
            auto b = _connection.recv(bufferSize);
            if (b.length == 0) {
                break;
            }
            _input_stream.put(b);
            while(true) {
                auto v = _input_stream.get();
                if (v.type == ValueType.Incomplete) {
                    break;
                }
                response ~= v;
                if (v.type == ValueType.Error
                        && cast(string) v.svar[4 .. 18] == "Protocol error") {
                    _connection.close();
                    debug (redisd)
                        trace("reopen connection");
                    _connection = _connection_maker();
                    _connection.connect(_connect_string);
                    _input_stream = new DecodeStream;
                    return response;
                }
            }
        }
        return response;
    }

    private RedisValue exec(RedisValue command) {
        RedisValue response;
        _connection.send(command.encode);
        while (true) {
            auto b = _connection.recv(bufferSize);
            if (b.length == 0) {
                break;
            }
            _input_stream.put(b);
            response = _input_stream.get();
            if (response.type != ValueType.Incomplete) {
                break;
            }
        }
        if (response.type == ValueType.Error && cast(string) response.svar[4 .. 18]
                == "Protocol error") {
            _connection.close();
            debug (redisd)
                trace("reopen connection");
            _connection = _connection_maker();
            _connection.connect(_connect_string);
            _input_stream = new DecodeStream;
        }
        return response;
    }

    RedisValue execCommand(A...)(A args) {
        immutable(ubyte)[][] data;
        RedisValue request = makeCommand(args);
        RedisValue response;
        _connection.send(request.encode);
        while(true) {
            auto b = _connection.recv(bufferSize);
            if ( b.length == 0 ) {
                // error, timeout or something bad
                break;
            }
            _input_stream.put(b);
            response = _input_stream.get();
            if (response.type != ValueType.Incomplete) {
                break;
            }
        }
        if ( response.type == ValueType.Error && 
                cast(string)response.svar[4..18] == "Protocol error") {
            _connection.close();
            debug(redisd) trace("reopen connection");
            _connection = _connection_maker();
            _connection.connect(_connect_string);
            _input_stream = new DecodeStream;
        }
        return response;
    }

    RedisValue set(K, V)(K k, V v) {
        return execCommand("SET", k, v);
    }

    RedisValue get(K)(K k) {
        return execCommand("GET", k);
    }

    RedisValue read() {
        RedisValue response;
        response = _input_stream.get();
        while(response.type == ValueType.Incomplete) {
            auto b = _connection.recv(bufferSize);
            if (b.length == 0) {
                break;
            }
            _input_stream.put(b);
            response = _input_stream.get();
            if (response.type != ValueType.Incomplete) {
                break;
            }
        }
        if (response.type == ValueType.Error && cast(string) response.svar[4 .. 18]
                == "Protocol error") {
            _connection.close();
            debug (redisd)
                trace("reopen connection");
            _connection = _connection_maker();
            _connection.connect(_connect_string);
            _input_stream = new DecodeStream;
        }
        return response;
    }

    void close() {
        _connection.close();
    }
}