module redisd.codec;

import std.string;
import std.algorithm;
import std.stdio;
import std.conv;
import std.exception;
import std.format;
import std.typecons;
import std.traits;
import std.array;
import std.range;

import std.experimental.logger;

///
enum ValueType : ubyte {
    Incomplete = 0,
    Null,
    Integer = ':',
    String = '+',
    BulkString = '$',
    List = '*',
    Error = '-',
}

class BadDataFormat : Exception {
    this(string msg, string f = __FILE__, ulong l = __LINE__) @safe {
        super(msg, f, l);
    }
}

class EncodeException : Exception {
    this(string msg, string f = __FILE__, ulong l = __LINE__) @safe {
        super(msg, f, l);
    }
}

class WrongOffset : Exception {
    this(string msg, string f = __FILE__, ulong l = __LINE__) @safe {
        super(msg, f, l);
    }
}

struct RedisValue {
    private {
        ValueType       _type;
        string          _svar;
        long            _ivar;
        RedisValue[]    _list;
    }
    ValueType type() @safe const {
        return _type;
    }

    bool empty() const {
        return _type == ValueType.Null;
    }

    string svar() @safe const {
        return _svar;
    }

    void opAssign(long v) @safe {
        _type = ValueType.Integer;
        _ivar = v;
        _svar = string.init;
        _list = RedisValue[].init;
    }

    void opAssign(string v) @safe {
        _type = ValueType.String;
        _svar = v;
        _ivar = long.init;
        _list = RedisValue[].init;
    }
    string toString() {
        switch(_type) {
        case ValueType.Incomplete:
            return "<Incomplete>";
        case ValueType.String:
            return "\"%s\"".format(_svar);
        case ValueType.Error:
            return "<%s>".format(_svar);
        case ValueType.Integer:
            return "%d".format(_ivar);
        case ValueType.BulkString:
            return "'%s'".format(_svar);
        case ValueType.List:
            return "[%(%s,%)]".format(_list);
        case ValueType.Null:
            return "(nil)";
        default:
            return "unknown type " ~ to!string(_type);
        }
    }
}

alias DecodeResult = Tuple!(RedisValue, "value", immutable(ubyte)[], "rest");

RedisValue redisValue(T)(T v) 
if (isSomeString!T || isIntegral!T) {
    RedisValue _v;
    static if (isIntegral!T) {
        _v._type = ValueType.Integer;
        _v._ivar = v;
    } else
    static if (isSomeString!T) {
        _v._type = ValueType.BulkString;
        _v._svar = v;
    } else {
        static assert(0, T.stringof);
    }
    return _v;
}

RedisValue redisValue(T)(T v) if (isTuple!T) {
    RedisValue _v;
    _v._type = ValueType.List;
    RedisValue[] l;
    foreach (element; v) {
        l ~= redisValue(element);
    }
    _v._list = l;
    return _v;
}

RedisValue redisValue(T:U[], U)(T v) 
if (isArray!T && !isSomeString!T) {
    RedisValue _v;
    _v._type = ValueType.List;
    RedisValue[] l;
    foreach (element; v) {
        l ~= redisValue(element);
    }
    _v._list = l;
    return _v;
}

immutable(ubyte)[] encode(RedisValue v) @safe {
    string encoded;
    switch(v._type) {
    case ValueType.Error:
        encoded.reserve(1 + v._svar.length + 2);
        encoded ~= "-";
        encoded ~= v._svar;
        encoded ~= "\r\n";
        return encoded.representation;
    case ValueType.String:
        encoded.reserve(1+v._svar.length+2);
        encoded ~= "+";
        encoded ~= v._svar;
        encoded ~= "\r\n";
        return encoded.representation;
    case ValueType.Integer:
        encoded.reserve(15);
        encoded ~= ":";
        encoded ~= to!string(v._ivar);
        encoded ~= "\r\n";
        return encoded.representation;
    case ValueType.BulkString:
        encoded.reserve(v._svar.length+1+20+2+2);
        encoded ~= "$";
        encoded ~= to!string(v._svar.length);
        encoded ~= "\r\n";
        encoded ~= to!string(v._svar);
        encoded ~= "\r\n";
        return encoded.representation;
    case ValueType.List:
        Appender!(immutable(ubyte)[]) appender;
        appender.put(("*" ~ to!string(v._list.length) ~ "\r\n").representation);
        foreach(element; v._list) {
            appender.put(element.encode);
        }
        return cast(immutable(ubyte)[])appender.data;
    default:
        throw new EncodeException("Failed to encode");
    }
}

@safe unittest {
    RedisValue v;
    v = "abc";
    assert(encode(v) == "+abc\r\n".representation);
    v = -1234567890;
    assert(encode(v) == ":-1234567890\r\n".representation);
    v = -0;
    assert(encode(v) == ":0\r\n".representation);

    v = -1234567890;
    assert(v.encode.decode.value == v);
    v = redisValue("abc");
    assert(v.encode.decode.value == v);
    v = redisValue([1,2]);
    assert(v.encode.decode.value == v);
    v = redisValue(tuple("abc", 1));
    assert(v.encode.decode.value == v);
}

DecodeResult decode(immutable(ubyte)[] data) @safe {
    assert(data.length >= 1);
    RedisValue v;
    switch(data[0]) {
    case '+':
        // simple string
        v._type = ValueType.String;
        auto s = data[1..$].findSplit([13,10]);
        v._svar = cast(string)s[0];
        return DecodeResult(v, s[2]);
    case '-':
        // error
        v._type = ValueType.Error;
        auto s = data[1 .. $].findSplit([13, 10]);
        v._svar = cast(string) s[0];
        return DecodeResult(v, s[2]);
    case ':':
        // integer
        v._type = ValueType.Integer;
        auto s = data[1 .. $].findSplit([13, 10]);
        v._ivar = to!long(cast(string)s[0]);
        return DecodeResult(v, s[2]);
    case '$':
        // bulk string
        // skip $, then try to split on first \r\n:
        // s now: [length],[\r\n],[data\r\n]
        v._type = ValueType.BulkString;
        auto s = data[1..$].findSplit([13, 10]);
        if (s[1].length != 2) {
            throw new BadDataFormat("bad data: [%(%02.2#x,%)]".format(data));
        }
        auto len = to!long(cast(string)s[0]);
        if ( s[2].length < len + 2 ) {
            throw new BadDataFormat("bad data: [%(%02.2#x,%)]".format(data));
        }
        v._svar = cast(string)s[2][0..len];
        return DecodeResult(v, s[2][len+2..$]);
    case '*':
        // list
        v._type = ValueType.List;
        auto s = data[1 .. $].findSplit([13, 10]);
        if (s[1].length != 2) {
            throw new BadDataFormat("bad data: [%(%02.2#x,%)]".format(data));
        }
        auto len = to!long(cast(string) s[0]);
        if ( len == 0 ) {
            return DecodeResult(v, s[2]);
        }
        if ( len == -1 ){
            v._type = ValueType.Null;
            return DecodeResult(v, s[2]);
        }
        auto rest = s[2];
        RedisValue[] array;

        while(len>0) {
            auto d = decode(rest);
            auto v0 = d.value;
            array ~= v0;
            rest = d.rest;
            len--;
        }
        v._list = array;
        return DecodeResult(v, rest);
    default:
        break;
    }
    assert(0);
}

@safe unittest {
    RedisValue v;
    v = "a";
    v = 1;
}

@safe unittest {
    DecodeResult d;
    d = decode("+OK\r\n ".representation);
    auto v = d.value;
    auto r = d.rest;

    assert(v._type == ValueType.String);
    assert(v._svar == "OK");
    assert(r == " ".representation);

    d = decode("-ERROR\r\ngarbage\r\n".representation);
    v = d.value;
    r = d.rest;
    assert(v._type == ValueType.Error);
    assert(v._svar == "ERROR");
    assert(r == "garbage\r\n".representation);

    d = decode(":100\r\n".representation);
    v = d.value;
    r = d.rest;
    assert(v._type == ValueType.Integer);
    assert(v._ivar == 100);
    assert(r == "".representation);

    d = decode("$8\r\nfoobar\r\n\r\n:41\r\n".representation);
    v = d.value;
    r = d.rest;
    assert(v._svar == "foobar\r\n", format("<%s>", v._svar));
    assert(r ==  ":41\r\n".representation);
    assert(v._type == ValueType.BulkString);

    d = decode("*3\r\n:1\r\n:2\r\n$6\r\nfoobar\r\nxyz".representation);
    v = d.value;
    r = d.rest;
    assert(v._type == ValueType.List);
    assert(r == "xyz".representation);
}

package alias Chunks = immutable(ubyte)[][];

struct Flat {
    private {
        Chunks              _chunks;
        immutable size_t    _totalLength;
    }
    this(Chunks c) @safe {
        _chunks = c;
        _totalLength = _chunks.map!"a.length".sum;
    }

    /// compare chunks bytes starting from `position` with buffer b
    private int cmp(size_t pos, const(ubyte)[] b) @safe {
        if ( _totalLength < b.length ) {
            return -1;
        }
        if ( pos >= _totalLength - 1 ) {
            throw new WrongOffset("%d>=%d".format(pos, _totalLength - 1));
        }
        int i;
        while( pos >= _chunks[i].length ) {
            pos -= _chunks[i].length;
            debug (redisd)
                tracef("skip chunk %d", i);
            i++;
        }
        debug(redisd) tracef("i=%d, pos=%d", i, pos);
        size_t bp;
        while(bp < b.length) {
            debug (redisd)
                tracef("i=%d, pos=%d, _chunks[i].length=%d, bp=%d", i, pos, _chunks[i].length, bp);
            auto v = _chunks[i][pos] - b[bp];
            if ( v != 0 ) {
                debug (redisd) tracef("return %d", v);
                return v;
            }
            bp++;
            pos++;
            if ( pos == _chunks[i].length ) {
                debug(redisd) trace("next chunk");
                pos = 0;
                i++;
            }
        }
        debug (redisd)
            tracef("return 0");
        return 0;
    }

    /// starting from prevpos count until byte b
    private size_t countUntil(size_t prevpos, ubyte b) @safe {
        size_t p = -1;
        int i, l;
        if (_chunks.length == 0)
            return p;
        while (prevpos > _chunks[i].length && i < _chunks.length - 1) {
            prevpos -= _chunks[i].length;
            l += _chunks[i].length;
            i++;
        }
        if (i == _chunks.length - 1 && prevpos >= _chunks[i].length) {
            throw new BadDataFormat("prev pos too far");
        }
        debug (redisd)
            tracef("l=%d, prevpos=%d", l, prevpos);

        while( i < _chunks.length ) {
            auto c = _chunks[i][prevpos..$].countUntil(b);
            if ( c >= 0 ) {
                debug (redisd)
                    tracef("l=%d, c=%d", l, c);
                return l+c;
            }
            l+=_chunks[i].length;
            prevpos = 0;
            i++;
        }

        return p;
    }

    /// starting from pos count until buffer 'b'
    private size_t countUntil(size_t pos, const(ubyte)[] b) @safe {
        if (b.length == 0) {
            throw new BadDataFormat("search for empty substr?");
        }
        if (pos == -1) {
            return -1;
        }
        if (_chunks.length == 0)
            return -1;

        auto needleLen = b.length;

        while ( pos < _totalLength - needleLen + 1 ) {
            debug(redisd) tracef("test position %d", pos);
            if ( cmp(pos, b) == 0 ) {
                return pos;
            }
            pos++;
        }
        return -1;
    }

    immutable(ubyte)[] data() @safe {
        immutable(ubyte)[] v;
        v.reserve(_totalLength);
        foreach(c; _chunks) {
            v ~= c;
        }
        return v;
    }

    // like substring but for chunks
    Flat sub(size_t from, size_t to) @safe {
        if ( from == to ) {
            return Flat([]);
        }
        if ( from < 0 || from >= _totalLength || to < from || to > _totalLength ) {
            throw new WrongOffset("from: %d, to: %d, length: %d".format(from, to, _totalLength));
        }
        Chunks d;
        int i;
        while(from >= _chunks[i].length) {
            from -= _chunks[i].length;
            to -= _chunks[i].length;
            i++;
        }
        while(to>0) {
            auto to_copy = min(to, _chunks[i].length);
            debug (redisd)
                tracef("copy chunk [%(0x%02.2x,%)][%d..%d]: [%(0x%02.2x,%)]", _chunks[i], from, to_copy, _chunks[i][from .. to_copy]);
            d ~= _chunks[i][from..to_copy];
            from = 0;
            to -= to_copy;
            i++;
        }
        return Flat(d);
    }

    // find and split of Flat buffers
    Flat[] findSplit(const(ubyte)[] b) @safe {
        immutable i = countUntil(0, b);
        if ( i == -1 ) {
            return new Flat[](3);
        }
        Flat[] f;
        f ~= sub(0, i);
        f ~= Flat([b.idup]);
        f ~= sub(i+b.length, _totalLength);
        return f;
    }
}

class DecodeStream {
    enum State {
        Init,
        Type,
    }
    private {
        Chunks          _chunks;
        State           _state;
        ValueType       _frontChunkType;
        size_t          _parsedPosition;
        size_t          _list_len;
        RedisValue[]    _list;
    }
    bool put(immutable(ubyte)[] chunk) @safe {
        assert(chunk.length > 0, "Chunk must not be emplty");
        if ( _chunks.length == 0 ) {
            switch( chunk[0]) {
            case '+','-',':','*','$':
                _frontChunkType = cast(ValueType)chunk[0];
                debug(redisd) tracef("new chunk type %s", _frontChunkType);
                break;
            default:
                throw new BadDataFormat("on chunk" ~ to!string(chunk));
            }
        }
        _chunks ~= chunk;
        //_len += chunk.length;
        return false;
    }

    private RedisValue _handleListElement(RedisValue v) @safe {
        // we processing list element
        () @trusted {debug(redisd) tracef("appending %s to list", v);} ();
        _list ~= v;
        _list_len--;
        if (_list_len == 0) {
            RedisValue result = {_type:ValueType.List, _list : _list};
            _list.length = 0;
            return result;
        }
        return RedisValue();
    }

    RedisValue get() @safe {
        RedisValue v;
    start:
        if (_chunks.length == 0 ) {
            return v;
        }
        Flat f = Flat(_chunks);
        Flat[] s;
        debug(redisd) tracef("check var type %c", cast(char)_chunks[0][0]);
        switch (_chunks[0][0]) {
        case ':':
            s = f.findSplit(['\r', '\n']);
            if ( s[1]._totalLength == 2 ) {
                v = to!long(cast(string)s[0].data[1..$]);
                _chunks = s[2]._chunks;
                if (_list_len > 0) {
                    v = _handleListElement(v);
                    if (_list_len)
                        goto start;
                }
                return v;
            }
            break;
        case '+':
            s = f.findSplit(['\r', '\n']);
            if (s[1]._totalLength == 2) {
                v = cast(string) s[0].data[1 .. $];
                _chunks = s[2]._chunks;
                if (_list_len > 0) {
                    v = _handleListElement(v);
                    if (_list_len)
                        goto start;
                }
                return v;
            }
            break;
        case '-':
            s = f.findSplit(['\r', '\n']);
            if (s[1]._totalLength == 2) {
                v._type = ValueType.Error;
                v._svar = cast(string) s[0].data[1 .. $];
                _chunks = s[2]._chunks;
                if (_list_len > 0) {
                    v = _handleListElement(v);
                    if (_list_len)
                        goto start;
                }
                return v;
            }
            break;
        case '$':
            s = f.findSplit(['\r', '\n']);
            if (s[1]._totalLength == 2) {
                size_t len = (cast(string)s[0].data[1..$]).to!long;
                if ( len == -1 ) {
                    v._type = ValueType.Null;
                    _chunks = s[2]._chunks;
                    if (_list_len > 0) {
                        v = _handleListElement(v);
                        if (_list_len)
                            goto start;
                    }
                    return v;
                }
                if (s[2]._totalLength < len + 2) {
                    return v;
                }
                auto data = s[2].sub(0, len).data;
                v = cast(string) data;
                _chunks = s[2].sub(data.length+2, s[2]._totalLength)._chunks;
                if (_list_len > 0) {
                    v = _handleListElement(v);
                    if (_list_len) goto start;
                }
            }
            break;
        case '*':
            _list_len = -1;
            s = f.findSplit(['\r', '\n']);
            if (s[1]._totalLength == 2) {
                size_t len = (cast(string) s[0].data[1 .. $]).to!long;
                _list_len = len;
                _chunks = s[2]._chunks;
                if (len == 0) {
                    v._type = ValueType.Null;
                    return v;
                }
                debug (redisd)
                    tracef("list of length %d detected", _list_len);
                goto start;            
            }
            break;
        default:
            break;
        }
        return v;
    }
}

@safe unittest {
    globalLogLevel = LogLevel.info;
    immutable(ubyte)[][] b = [
        "123".representation,
        "456".representation,
        "789".representation
    ];
    auto f = Flat(b);
    auto p = f.countUntil(0, '3');
    assert(p==2);

    p = f.countUntil(4, '3');
    assert(p==-1);

    p = f.countUntil(0, '4');
    assert(p == 3);

    assertThrown!BadDataFormat(f.countUntil(10, '4'));

    p = f.countUntil(0, "34".representation);
    assert(p == 2, "expected 2, got %d".format(p));

    p = f.countUntil(0, "34567".representation);
    assert(p == 2, "expected 2, got %d".format(p));

    p = f.countUntil(0, "6789".representation);
    assert(p == 5, "expected 5, got %d".format(p));
    p = f.countUntil(0, "456".representation);
    assert(p == 3, "expected 3, got %d".format(p));

    auto s0 = f.sub(0, 6);
    assert(s0._chunks == ["123".representation,"456".representation]);

    auto s1 = f.sub(3, 6);
    assert(s1._chunks == ["456".representation], "%s".format(s1));

    auto s2 = f.sub(5, 6);
    assert(s2._chunks == ["6".representation], "%s".format(s2));

    auto split = f.findSplit("5".representation);
    split = f.findSplit("567".representation);
    info("test 1 ok");
}

@safe unittest {
    globalLogLevel = LogLevel.info;
    RedisValue str = {_type:ValueType.String, _svar : "abc"};
    RedisValue err = {_type:ValueType.Error, _svar : "err"};
    auto b = redisValue(1001).encode 
            ~ redisValue(1002).encode
            ~ str.encode
            ~ err.encode
            ~ redisValue("\r\nBulkString\r\n").encode
            ~ redisValue(1002).encode
            ~ redisValue([1,2,3]).encode
            ~ redisValue(["abc", "def"]).encode
            ~ redisValue(1002).encode;

    foreach(chunkSize; 1..b.length) {
        auto s = new DecodeStream();
        foreach (c; b.chunks(chunkSize)) {
            s.put(c);
        }
        auto v = s.get();
        assert(v._ivar == 1001);
        v = s.get();
        assert(v._ivar == 1002);
        v = s.get();
        assert(v._svar == "abc");
        v = s.get();
        assert(v._svar == "err");
        v = s.get();
        assert(v._svar == "\r\nBulkString\r\n");
        v = s.get();
        assert(v._ivar == 1002);
        int lists_to_get = 2;
        while( lists_to_get>0 ) {
            v = s.get();
            debug (redisd)
                () @trusted { tracef("%s: %s, %s", v._type, v, lists_to_get); }();
            if (v._type == ValueType.List) {
                lists_to_get--;
            }
        }
        v = s.get();
        assert(v._ivar == 1002);
        v = s.get();
        assert(v._type == ValueType.Incomplete);
    }
    info("test 2 ok");
}