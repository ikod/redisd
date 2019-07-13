module redisd.connection;

import std.algorithm;
import std.conv;
import std.stdio;

import url:URL;

interface Connection {
    void connect(URL) @safe;
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
        _socket.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);

    }

    override void connect(URL url) @safe {
        string host = url.host;
        ushort port = url.port;
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

version(vibe) {
    import vibe.vibe;
    import vibe.core.net;
    import eventcore.core;
    import std.exception;
    import std.socket;

    Connection vibeConnectionMaker() @safe {
        return new VibeSocketConnection();
    }
    ///
    class VibeSocketConnection: Connection {
        private {
            TCPConnection _socket;
        }
        ///
        this() @safe {
        }
        override void connect(URL url) {
            auto a = getAddressInfo(url.host, AddressFamily.INET);
            _socket = connectTCP(a[0].address.toAddrString, url.port);
        }

        override immutable(ubyte)[] recv(size_t to_receive) {
            ubyte[] result;
            result.length = to_receive;
            auto r = _socket.read(result, IOMode.once);
            if (r <= 0) {
                return assumeUnique(result[0 .. 0]);
            }
            return assumeUnique(result[0..r]);
        }

        override size_t send(immutable(ubyte)[] data) {
            try {
                auto r = _socket.write(data, IOMode.all);
                return r;
            } catch (Exception e) {
                logError(e.toString);
                return -1;
            }
        }

        override void close() {
            _socket.close();
        }
    }
}

version(hio) {
    import std.datetime;
    import std.socket;
    import std.format;
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

        override void connect(URL url) {
            auto a = getAddressInfo(url.host, AddressFamily.INET);
            _socket.connect("%s:%d".format(a[0].address.toAddrString, url.port), 1.seconds);
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