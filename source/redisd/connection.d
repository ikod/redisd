module redisd.connection;

import std.algorithm;
import std.conv;
import std.stdio;

interface Connection {
    void connect(string) @safe;
    size_t send(immutable(ubyte)[]);
    immutable(ubyte)[] recv(size_t);
    void close();
}

alias ConnectionMaker = Connection function() @safe;

class SocketConnection : Connection {
    import std.socket;
    private {
        string  _host;
        ushort  _port;
        Socket  _socket;
    }

    this() @safe {
        _socket = new Socket(AddressFamily.INET, SocketType.STREAM);
    }

    override void connect(string connect_string) @safe {
        auto s = connect_string.findSplit(":");
        string host = s[0];
        ushort port = to!ushort(s[2]);
        auto addr = new InternetAddress(host, port);
        _socket.connect(addr);
    }

    override immutable(ubyte)[] recv(size_t to_receive) {
        immutable(ubyte)[] result;
        result.length = to_receive;
        auto r = _socket.receive(cast(void[])result);
        if ( r <= 0 ) {
            return result[0..0];
        }
        return result[0..r];
    }

    override size_t send(immutable(ubyte)[] data) {
        return _socket.send(cast(void[])data, SocketFlags.NONE);
    }

    override void close() {
        _socket.close();
    }

}

Connection stdConnectionMaker() @safe {
    return new SocketConnection();
}

version(hio) {
    import std.datetime;
    import hio.socket;
    import hio.events;

    Connection hioConnectionMaker() @safe {
        return new HioSocketConnection();
    }

    class HioSocketConnection : Connection {
        private {
            HioSocket   _socket;
        }

        this() @safe {
            _socket = new HioSocket();
        }

        override void connect(string connect_string) {
            _socket.connect(connect_string, 1.seconds);
        }

        override immutable(ubyte)[] recv(size_t to_receive) {
            immutable(ubyte)[] result;
            result.length = to_receive;
            IOResult r = _socket.recv(to_receive);
            if ( r.error || r.input.length == 0) {
                return result[0..0];
            }
            return r.input;
        }

        override size_t send(immutable(ubyte)[] data) {
            return _socket.send(data, 1.seconds);
        }

        override void close() {
            _socket.close();
        }
    }
}