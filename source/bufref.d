module bufref;

import std.range.primitives;

// arrays and random-access non-infinite ranges are buffers.
template isBuffer(B)
{
    import std.range.primitives : isRandomAccessRange, isInfinite;
    import std.traits : isDynamicArray;
    enum isBuffer = isDynamicArray!B || (isRandomAccessRange!B && !isInfinite!B);
}

struct BufRef
{
    size_t pos;
    size_t length;
}

enum isBufRef(alias item) = is(typeof(item) == BufRef);
enum isBufRefRange(alias item) = isInputRange!(typeof(item)) && is(ElementType!(typeof(item)) == BufRef);

template hasBufRefs(T)
{
    // type has at least one bufRef item as a member
    static if(is(T == struct))
    {
        import std.meta : anySatisfy;
        enum hasBufRefs = anySatisfy!(isBufRef, T.tupleof) || anySatisfy!(isBufRefRange, T.tupleof);
    }
    else
        enum hasBufRefs = false;
}


unittest
{
    static struct S1
    {
        string member1;
        BufRef member2;
        int member3;
    }

    static assert(hasBufRefs!S1);

    static struct S2
    {
        int member1;
        string member2;
    }

    static assert(!hasBufRefs!S2);

    static struct S3
    {
        BufRef[] arr;
    }

    static assert(hasBufRefs!S3);
}

// Wrapper for a BufRef range that exposes elements as concrete buffer slices.
// Does not make any copies of items.
struct ConcreteRange(R, W) if (isInputRange!R && is(ElementType!R == BufRef) && isBuffer!W)
{
    R r;
    W w;
    auto front()
    {
        return r.front.concrete(w);
    }

    void popFront()
    {
        r.popFront;
    }

    bool empty()
    {
        return r.empty;
    }
    
    static if(isForwardRange!R)
    {
        ConcreteRange save()
        {
            return ConcreteRange(r.save, w);
        }
    }

    static if(isBidirectionalRange!R)
    {
        auto back()
        {
            return r.back.concrete(w);
        }

        void popBack()
        {
            r.popBack;
        }
    }

    static if(hasLength!R)
    {
        size_t length()
        {
            return r.length;
        }

        auto opDollar(size_t dim)() if (dim == 0)
        {
            return length;
        }
    }

    static if(is(typeof(r[0])))
    {
        auto opIndex(size_t idx)
        {
            return r[idx].concrete(w);
        }
    }

    static if(hasSlicing!R)
    {
        size_t[2] opSlice(size_t dim)(size_t start, size_t end) if (dim == 0)
        {
            return [start, end];
        }

        auto opIndex(size_t[2] idx)
        {
            return ConcreteRange(r[idx[0] .. idx[1]], w);
        }
    }
}

// get a concrete represenation of the buffer reference
auto concrete(B)(const(BufRef) bref, B window) if (isBuffer!B)
{
    return window[bref.pos .. bref.pos + bref.length];
}

// get a concrete range from a range of buffer references.
auto concrete(R, B)(R brefRange, B window) if (isBufRefRange!brefRange && isBuffer!B)
{
    return ConcreteRange!(R, B)(brefRange, window);
}

// get a concrete representation of an item that contains buffer references.
// DOES NOT copy functions.
auto concrete(T, B)(auto ref T item, B window) if (hasBufRefs!T && isBuffer!B)
{
    BufRef test;
    alias SliceType = typeof(BufRef.init.concrete(window));
    static string resultstr()
    {
        string result = "static struct Concrete" ~ T.stringof ~ " {";
        static foreach(i; 0 .. T.tupleof.length)
        {{
             alias TE = typeof(T.tupleof[i]);
             static if(is(TE == BufRef))
             {
                 // replace with the slice type
                 result ~= "SliceType " ~ __traits(identifier, T.tupleof[i]) ~ ";";
             }
             else static if(isInputRange!TE && is(ElementType!TE == BufRef))
             {
                 result ~= "ConcreteRange!( " ~ TE.stringof ~ ",B) " ~ __traits(identifier, T.tupleof[i]) ~ ";";
             }
             else
             {
                 result ~= typeof(T.tupleof[i]).stringof ~ " " ~ __traits(identifier, T.tupleof[i]) ~ ";";
             }
        }}
        result ~= "} alias Result = Concrete" ~ T.stringof ~ ";";
        return result;
    }
    mixin(resultstr());
    Result r;
    foreach(i, ref it; item.tupleof)
    {
        static if(isBufRef!(item.tupleof[i]) || isBufRefRange!(item.tupleof[i]))
        {
            r.tupleof[i] = it.concrete(window);
        }
        else
        {
            r.tupleof[i] = it;
        }
    }
    return r;
}

unittest
{
    static struct S
    {
        int i;
        BufRef b;
        long l;
        BufRef[] barr;
    }
    S s;
    s.b = BufRef(0, 10);
    s.barr = [BufRef(0, 2), BufRef(1, 2), BufRef(2, 2)];
    auto c = s.concrete("0123456789012345");
    assert(c.b == "0123456789");
    assert(c.barr.length == 3);
    assert(c.barr[0] == "01");
    assert(c.barr[1] == "12");
    assert(c.barr[2] == "23");
    assert(c.barr[1 .. $][0] == "12");
}

// adjust the pos of the reference inside the buffer.
void adjustPos(ref BufRef bref, ptrdiff_t adjustment)
{
    assert(cast(ptrdiff_t)(bref.pos + adjustment) >= 0);
    bref.pos += adjustment;
}

// adjust the pos of all the buffer references inside the item.
void adjustPos(T)(ref T item, ptrdiff_t adjustment) if (hasBufRefs!T)
{
    foreach(i, ref it; item.tupleof)
    {
        static if(is(typeof(it) == BufRef))
        {
            it.adjustPos(adjustment);
        }
        else static if(is(typeof(it[]) == BufRef[]))
        {
            foreach(ref br; it[])
                br.adjustPos(adjustment);
        }
        else static if(isBufRefRange!(item.tupleof[i]) && isForwardRange!(typeof(it)) && hasLvalueElements!(typeof(it)))
        {
            foreach(ref br; it.save)
                br.adjustPos(adjustment);
        }
    }
}

// a buffer window. This wraps a buffer into a range that knows what position
// it's at in the original window.
auto bwin(B)(B window) if (isBuffer!B)
{
    static struct Result
    {
        private size_t pos;
        private B _buffer;

        import std.traits : isNarrowString;
        static if(isNarrowString!B)
        {
            auto ref front()
            {
                return _buffer[0];
            }

            void popFront()
            {
                ++pos;
                _buffer = _buffer[1 .. $];
            }
            
            auto ref back()
            {
                return _buffer[$-1];
            }

            void popBack()
            {
                _buffer = _buffer[0 .. $-1];
            }
        }
        else
        {
            auto ref front()
            {
                return _buffer.front;
            }

            void popFront()
            {
                ++pos;
                _buffer.popFront;
            }
            
            auto ref back()
            {
                return _buffer.back;
            }

            void popBack()
            {
                _buffer.popBack;
            }
        }

        size_t length()
        {
            return _buffer.length;
        }

        auto ref opIndex(size_t idx)
        {
            return _buffer[idx];
        }

        // implement the slice operations
        size_t[2] opSlice(size_t dim)(size_t start, size_t end) if (dim == 0)
        in
        { assert(start >= 0 && end <= _buffer.length); }
        do
        {
            return [start, end];
        }

        Result opIndex(size_t[2] dims)
        {
            return Result(pos + dims[0], _buffer[dims[0] .. dims[1]]);
        }

        Result save()
        {
            return this;
        }

        bool empty()
        {
            return _buffer.empty;
        }

        // the specialized buffer reference accessor.
        @property auto bufRef()
        {
            return BufRef(pos, _buffer.length);
        }
    }

    return Result(0, window);
}

unittest
{
    import std.algorithm : splitter, equal;
    auto buf = "hi there this is a sentence";
    auto split1 = buf.bwin.splitter(" ");

    auto split2 = buf.splitter;
    while(!split1.empty)
    {
        assert(split1.front.equal(split2.front));
        assert(split1.front.bufRef.concrete(buf) == split2.front);
        split1.popFront;
        split2.popFront;
    }
}
