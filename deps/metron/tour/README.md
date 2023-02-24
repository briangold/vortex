# A guided tour of Metron 

The examples in this directory serve as a reference for how to write
microbenchmarks with Metron. This README serves as a guide from simple to
advanced customization.

| Section| Concept |
| :---  | :---    |
| [An empty loop](#an-empty-loop) | Core iteration loop |
| [Test fixtures](#test-fixtures-for-setup-and-teardown) | Setup and teardown work |
| [Parameterizing args](#parameterized-args) | Measuring a function of one variable |
| [Parameterized ranges](#parameterizing-arguments-over-ranges) | Define arguments over a range |
| [Compound args](#functions-of-multiple-arguments) | Functions with multiple arguments |
| [Bytes](#working-with-bytes-displaying-units-and-bytes-processed) | Measuring and reporting bytes |
| [Multithreading](#multithreaded-tests) | Running multi-threaded tests |

## An empty loop

Code in [`empty.zig`](empty.zig)

The empty test serves as a calibration experiment, measuring the cost of a loop
that does no apparent work. 

```zig
pub fn simple(state: *State) void {
    var iter = state.iter();
    while (iter.next()) |i| {
        std.mem.doNotOptimizeAway(i);
    }
}
```

Although it seems like a trivial exercise, there's a fair bit of work happening
behind the scenes that should compile down to a loop of ~4 instructions on
modern systems. 

The iterator returned by `state.iter()` governs how many iterations of the loop
are required to get a stable measurement. Metron will invoke the `simple`
function with increasing iteration counts to ensure the test runs for a minimum
measurement interval (by default, 1 second). By default, the test runner starts
with an iteration count of 1, but in this case we've set `min_iter = 100` to
start with 100 iterations. This makes it easy to start in a debugger, set a
breakpoint on the while loop, and observe the inner loop that is executed.

When the iterator is created a timer is started, and when the last iteration is
reached the timer is stopped and the duration is recorded by the Metron test
runner that orchestrates the benchmark.

In this simple test, each iteration of the while loop simply increments a
counter and compares that with the requested count.  In a release build, the
iteration counter and its limit value will likely be kept in registers, allowing
the core of this loop to be ~3 instructions (depending on ISA specifics and
compiler optimizations). In practice, we see a fourth instruction that comes
from odd-looking `std.mem.doNotOptimizeAway(i)` call.

The call to `std.mem.doNotOptimizeAway(i)` is there to tell the compiler that
we do not want the loop to be optimized out, which is necessary in this test 
(and many others) because it's clear we're not doing any useful work. Modern
compilers are incredibly sophisticated, and microbenchmark authors must take
extreme care to ensure the compiler hasn't outstmarted them and effectively
removed the code they wanted to measure.

## Test fixtures for setup and teardown

Code in [`empty.zig`](empty.zig)

The empty test has a second public function, `fixture`, which runs the same test
as the `simple` function discussed above. There are two demonstration goals
here. First, the `fixture` function is treated alongside `simple` as alternate
functions to benchmark. The test runner will analyze both, in turn, calling them
with the same sets of arguments. We can see the output of each test indicates
which function was called. If a benchmark has a single public function, the name
will not be shown. Private functions are not called by the test runner.

    ----------------------------------------
    Benchmark              Time   Iterations
    ----------------------------------------
    empty/simple       0.314 ns   4432560342
    empty/fixture      0.313 ns   4492003409

The second purpose of `fixture` is to demonstrate that additional processing
before the loop does not disrupt the timing. Code that is run before the
creation of the iterator can perform complex setup operations, and while it
serves no purpose in this trivial example, more complex tests (especially
multi-threaded tests) can use this approach to setup and teardown needed
structures.

## Parameterized args

Code in [`fib.zig`](fib.zig)

In many benchmarking experiments, we have a parameter that affects the amount
of work in a function. In this example, we benchmark two implementations of
a fibonacci-sequence function that computes the length of the sequence up to 
a given parameter `n`. To vary the value of `n`, the test contains:

```zig
    pub const args = [_]usize{ 1, 2, 5, 10, 20 };
```

which defines an explicit set of values to test. The output will show the timing
of each argument value for both recursive and sequential implementations:

```
--------------------------------------------
Benchmark                  Time   Iterations
--------------------------------------------
fib/recurse/1           1.26 ns    997821058
fib/recurse/2           3.10 ns    498379490
fib/recurse/5           12.9 ns    109560809
fib/recurse/10           156 ns      8955079
fib/recurse/20         20284 ns        69097
fib/sequential/1       0.471 ns   2999882848
fib/sequential/2       0.469 ns   2996438155
fib/sequential/5        1.57 ns    897837702
fib/sequential/10       3.12 ns    449453236
fib/sequential/20       6.25 ns    224833009
```

## Parameterizing arguments over ranges

Code in [`bitset.zig`](bitset.zig) 

Explicitly writing argument slices is tedious and error-prone. Metron provides
helper functions for common range-specifiers. In this test, we use:

```zig
pub const args = range(usize, 2, 8, 1024);
```

to build a comptime-slice of `usize` values from 8 to 1024 (inclusive) in
power-of-2 steps. The test runs each variation as we'd expect:

```
--------------------------------------
Benchmark            Time   Iterations
--------------------------------------
bitset/8         0.785 ns   1796366659
bitset/16        0.782 ns   1790860824
bitset/32        0.783 ns   1798785255
bitset/64        0.782 ns   1797592732
bitset/128        1.06 ns   1323980796
bitset/256        1.17 ns   1188913759
bitset/512        1.68 ns    835523912
bitset/1024       2.83 ns    488848223
```

There is also a `denseRange` helper if you just want a linear slice of values:

```zig
pub const args = denseRange(usize, 5, 13);
```

creates a slice with values `{ 5, 6, ..., 13 }`.

## Functions of multiple arguments

Code in [`roots.zig`](roots.zig) 

Metron requires the test definition to provide a slice for `args`. When a
function needs to be parameterized in more than one argument, a slice-of-structs
(or, equivalently, a slice-of-tuples) can be provided.

The `argsProduct` function makes it easy to derive the cartesian product of an 
independent set of dimensions. For example, in this test we have:

```zig
pub const args = argsProduct(.{
    .n = [_]usize{ 1, 2, 5, 8 }, // polynomial degree
    .a = [_]f64{ 1.1, 11.0 }, // root to find
});
```

The resulting `args` slice is equivalent to:

```zig
pub const args = [_]struct {n: usize, a: f64}{
    .{ .n = 1, .a = 1.1 },
    .{ .n = 1, .a = 11.0 },
    .{ .n = 2, .a = 1.1 },
    // ...
    .{ .n = 8, .a = 11.0 },
};
```

To aid in reporting, we set the `arg_names` slice so each field of the arg
struct is printed as part of the test name, along with its value:

```
------------------------------------------
Benchmark                Time   Iterations
------------------------------------------
roots/n:1/a:1.1       6.88 ns    204113043
roots/n:1/a:11        6.86 ns    203579726
roots/n:2/a:1.1       73.7 ns     18942756
roots/n:2/a:11         247 ns      5594581
roots/n:5/a:1.1        348 ns      4394095
roots/n:5/a:11         867 ns      1614133
roots/n:8/a:1.1        547 ns      2615610
roots/n:8/a:11        1531 ns       912330
```

## Working with bytes: displaying units and bytes processed

Code in [`memcpy.zig`](memcpy.zig)

For tests that work with byte buffers, slices, arrays, etc. it's common to
define performance by the throughput in bytes/second. We can report transfer
rates by defining a `Counters` type in the test definition, for example:

```zig
pub const Counters = struct {
    rate: ByteCounter(.div_1024) = .{},
};
```

By specifying `ByteCounter(.div_1024)`, we indicate base-2 reporting (e.g.,
MiB/s instead of MB/s) for this counter. We then change the return type of our
test function to `Counters` and return an instance:

```zig
return Counters{
    .rate = .{ .val = n * state.iterations },
};
```

In this example, `n` is the parameterized argument--how many bytes to copy per
iteration--and `state.iterations` is the total number of iterations.

In addition, we set the test-level `arg_units` to `.div_1024` to control how the
size argument and is reported. 

```zig
pub const arg_units = .div_1024;
```

We can see the resulting output as follows:

```
--------------------------------------
Benchmark            Time   Iterations
--------------------------------------
memcpy/1k         13.5 ns     94405142 rate=70.397GiB/s
memcpy/4k         55.7 ns     25546583 rate=68.541GiB/s
memcpy/16k         216 ns      6413293 rate=70.578GiB/s
memcpy/64k         807 ns      1760003 rate=75.655GiB/s
memcpy/256k       3579 ns       342741 rate=68.209GiB/s
memcpy/1M        17289 ns        63727 rate=56.484GiB/s
memcpy/4M        70688 ns        20020 rate=55.261GiB/s
memcpy/16M      552464 ns         2507 rate=28.282GiB/s
memcpy/64M     2455544 ns          557 rate=25.453GiB/s
```

Note: In multi-threaded tests, each thread computes its byte count and the
reported totals are aggregated over all threads. This sample is single-threaded.

## Multithreaded tests

Code in [`threads.zig`](threads.zig)

By adding a `threads` declaration to the test specification, Metron will treat
the thread count as another parameter for the test. 

```zig
pub const threads = [_]usize{ 1, 2, 4, 8 };
```

The `Time` reported by Metron is always wall-clock time as recorded by the main
thread, and a barrier synchronizes the threads just after the timer is started
and prior to stopping the timer. Each thread does the same amount of work
(`state.iterations`). If the wall-clock time stays the same, but the total work
doubles, the per-operation time reported will be halved.

This example shows three variants of a trivial counter:

1. The `uncoord()` version shows an empty loop that "counts" local to each
thread but performs no synchronization. It's useful to understand what
completely independent work looks like in the reported output.

2. The `fetchAdd()` version performs an atomic fetch-and-add operation using  
atomic memory operations. 

3. The `localAdd()` version produces the same final result as `fetchAdd()`, but
only performs the atomic fetch-and-add on the last iteration, adding all of its
locally accumulated counts to the shared location.

The results on a 6+2-core (6 performance and 2 efficiency) M1 laptop show:

```
-------------------------------------------------------
Benchmark                           Time     Iterations
-------------------------------------------------------
threads/uncoord/threads:1       0.312 ns     4449969229 rate=3.205Gadd/s
threads/uncoord/threads:2       0.160 ns     8076257172 rate=6.245Gadd/s
threads/uncoord/threads:4       0.082 ns    17200617448 rate=12.187Gadd/s
threads/uncoord/threads:8       0.054 ns    28169300448 rate=18.490Gadd/s
threads/fetchAdd/threads:1       6.24 ns      223462527 rate=160.280Madd/s
threads/fetchAdd/threads:2       12.3 ns      110394314 rate=81.158Madd/s
threads/fetchAdd/threads:4       35.8 ns       53047904 rate=27.945Madd/s
threads/fetchAdd/threads:8       46.9 ns       32314416 rate=21.326Madd/s
threads/localAdd/threads:1      0.312 ns     4257154435 rate=3.206Gadd/s
threads/localAdd/threads:2      0.160 ns     8768300400 rate=6.249Gadd/s
threads/localAdd/threads:4      0.082 ns    17092291012 rate=12.246Gadd/s
threads/localAdd/threads:8      0.056 ns    25370656512 rate=17.893Gadd/s
```

The `uncoord` variant shows that using 2 threads results in roughly half the
time per effective operation, and 4 threads is half again. But with 8 threads we
start scheduling on the efficiency cores and performance doesn't scale linearly.

In contrast, the `fetchAdd` variant starts out 20x slower and actually slows
down with each additional thread. Synchronization operations (`ldrex/strex` in
ARM) stall the processor pipeline and adding threads introduces additional
contention on the shared variable. By deferring the synchronization work to the
final iteration, `localAdd` returns to the performance of the `uncoord` version
while still producing the same result as the contended `fetchAdd`.

This sample also shows a custom counter to measure the rate of additions
per-second across all running threads. Each thread returns its count and the
test runner accumulates them.
